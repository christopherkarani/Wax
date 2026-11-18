#!/usr/bin/env python3
"""
Convert cross-encoder/ms-marco-MiniLM-L-6-v2 (Apache-2.0) to CoreML (.mlpackage -> .mlmodelc).

Follows scripts/convert_e5_small_v2.py so the reranker shares the embedders' runtime contract:
  - Flexible shapes: batch 1...64 x sequence 32...512. MiniLMReranker pads each batch to one of
    MiniLMRerankerModel.sequenceLengthBuckets: [32, 64, 128, 192, 256, 288, 384, 512]
  - FP16 compute over INT8 per-channel symmetric weights (--weights int8, the default),
    or uncompressed FP32 weights (--weights fp32) for checking quantization error
  - Inputs: input_ids, attention_mask, token_type_ids (BERT segment ids: 0 for
    [CLS] query [SEP], 1 for the passage window and its closing [SEP])
  - Output: `scores`, the raw relevance logit per row ([batch, 1]), the value
    sentence-transformers' CrossEncoder.predict returns for this model (Identity activation)
  - Eager attention (not SDPA) for coremltools compatibility
  - Finite additive attention-mask fill `(1 - mask) * -1e4` instead of Hugging Face's
    `finfo(float32).min`, which becomes -inf in Float16 and turns padded rows into NaN
  - macOS 15+ / iOS 18+

The model uses the bert-base-uncased WordPiece vocabulary, byte-identical to
Sources/WaxBertTokenizer/Resources/bert_tokenizer_vocab.txt, so no new vocab ships.

Requirements:
    transformers>=4.44,<5.0 torch>=2.5,<2.8 coremltools>=8.0 numpy

Usage:
    python -I scripts/convert_ms_marco_minilm_reranker.py [--weights int8|fp32]

Output:
    Sources/WaxRerankerMiniLM/Resources/ms-marco-MiniLM-L-6-v2.mlmodelc
"""

import argparse
import os
import shutil
import subprocess
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_NAME = "cross-encoder/ms-marco-MiniLM-L-6-v2"
MODEL_REVISION = "233902d25c440f23af6f7d6e94d2946bac0bee0a"
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources",
    "WaxRerankerMiniLM",
    "Resources",
)
MODEL_BASENAME = "ms-marco-MiniLM-L-6-v2"

# Must match MiniLMRerankerModel.sequenceLengthBuckets.
MIN_SEQUENCE_LENGTH = 32
MAX_SEQUENCE_LENGTH = 512
# Must match MiniLMRerankerModel.maximumPredictionBatchSize.
MAX_BATCH_SIZE = 64

# Finite additive mask fill, representable in Float16 (max ~6.5e4).
MASK_FILL = -1.0e4


class CrossEncoderWrapper(nn.Module):
    """BERT encoder + pooler + classifier with a Float16-safe additive attention mask."""

    def __init__(self, hf_model: nn.Module) -> None:
        super().__init__()
        self.bert = hf_model.bert
        self.classifier = hf_model.classifier

    def forward(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor,
        token_type_ids: torch.Tensor,
    ) -> torch.Tensor:
        mask = attention_mask.to(torch.float32)
        additive = (1.0 - mask[:, None, None, :]) * MASK_FILL
        hidden = self.bert.embeddings(input_ids=input_ids, token_type_ids=token_type_ids)
        outputs = self.bert.encoder(hidden, attention_mask=additive)
        sequence = outputs[0] if isinstance(outputs, tuple) else outputs.last_hidden_state
        pooled = self.bert.pooler(sequence)
        return self.classifier(pooled)


def compiled_size_mb(path: str) -> float:
    total = sum(
        os.path.getsize(os.path.join(directory, name))
        for directory, _, files in os.walk(path)
        for name in files
    )
    return total / (1024 * 1024)


def convert(weights: str, output_dir: str) -> None:
    mlpackage_path = os.path.join(output_dir, f"{MODEL_BASENAME}.mlpackage")
    mlmodelc_path = os.path.join(output_dir, f"{MODEL_BASENAME}.mlmodelc")

    print(f"Loading model: {MODEL_NAME}@{MODEL_REVISION}")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME, revision=MODEL_REVISION)
    hf_model = AutoModelForSequenceClassification.from_pretrained(
        MODEL_NAME, revision=MODEL_REVISION, attn_implementation="eager", torchscript=True
    )
    hf_model.eval()

    wrapper = CrossEncoderWrapper(hf_model).eval()
    dummy_ids = torch.randint(0, tokenizer.vocab_size, (1, MIN_SEQUENCE_LENGTH), dtype=torch.int32)
    dummy_mask = torch.ones(1, MIN_SEQUENCE_LENGTH, dtype=torch.int32)
    dummy_types = torch.zeros(1, MIN_SEQUENCE_LENGTH, dtype=torch.int32)

    print("Tracing model...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask, dummy_types))

    batch_dim = ct.RangeDim(lower_bound=1, upper_bound=MAX_BATCH_SIZE, default=1)
    sequence_dim = ct.RangeDim(
        lower_bound=MIN_SEQUENCE_LENGTH, upper_bound=MAX_SEQUENCE_LENGTH, default=MIN_SEQUENCE_LENGTH
    )
    shape = ct.Shape(shape=[batch_dim, sequence_dim])

    print("Converting to CoreML (FP16 compute)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=shape, dtype=np.int32),
        ],
        # FP32 output, so MiniLMRerankerModel reads the same type either way.
        outputs=[ct.TensorType(name="scores", dtype=np.float32)],
        convert_to="mlprogram",
        # FP16 compute nearly halves CPU reranking time (LoCoMo p50 338 to 180 ms) and
        # changes R_all@5 by one question in 1,535. The finite MASK_FILL keeps padded
        # rows out of FP16 overflow.
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )

    if weights == "int8":
        print("Compressing weights to INT8 (per-channel symmetric)...")
        op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype=np.int8,
            granularity="per_channel",
        )
        config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
        mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)

    mlmodel.author = "Wax"
    mlmodel.license = "Apache-2.0 (cross-encoder/ms-marco-MiniLM-L-6-v2)"
    mlmodel.short_description = (
        "cross-encoder/ms-marco-MiniLM-L-6-v2 relevance logit for a (query, passage) pair "
        f"({weights.upper()} weights, FP16 compute)."
    )
    mlmodel.version = "1.0"

    os.makedirs(output_dir, exist_ok=True)
    if os.path.exists(mlpackage_path):
        shutil.rmtree(mlpackage_path)
    print(f"Saving mlpackage to: {mlpackage_path}")
    mlmodel.save(mlpackage_path)

    if os.path.exists(mlmodelc_path):
        shutil.rmtree(mlmodelc_path)
    print(f"Compiling to mlmodelc: {mlmodelc_path}")
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Compilation failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    if os.path.exists(mlpackage_path):
        shutil.rmtree(mlpackage_path)

    if not os.path.exists(mlmodelc_path):
        print("Error: .mlmodelc not found after compilation", file=sys.stderr)
        sys.exit(1)
    print(f"Success! Model compiled to {mlmodelc_path} ({compiled_size_mb(mlmodelc_path):.1f} MB)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", choices=["int8", "fp32"], default="int8")
    parser.add_argument("--output-dir", default=OUTPUT_DIR)
    args = parser.parse_args()
    convert(args.weights, args.output_dir)
