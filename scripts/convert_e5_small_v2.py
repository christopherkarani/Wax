#!/usr/bin/env python3
"""
Convert intfloat/e5-small-v2 (MIT) to CoreML (.mlpackage -> .mlmodelc).

Mirrors scripts/convert_arctic_embed.py so both opt-in embedders share one runtime contract:
  - Flexible shapes: batch 1...64 x sequence 32...512. Wax's BertTokenizer pads to the
    sequenceLengthBuckets in E5Embeddings.swift: [32, 64, 128, 256, 384, 512]
  - FP16 compute, INT8 per-channel symmetric weights (~32 MB)
  - Mean pooling over the attention mask + L2 normalization baked into the graph, matching
    sentence-transformers' e5-small-v2 pooling. The graph takes token ids; E5Embedder adds
    the "query: " / "passage: " prefixes in Swift before tokenizing
  - Eager attention (not SDPA) for coremltools compatibility
  - Finite additive attention-mask fill `(1 - mask) * -1e4` instead of Hugging Face's
    `finfo(float32).min`, which becomes -inf in Float16 and turns padded rows into NaN
  - macOS 15+ / iOS 18+

e5-small-v2 uses the bert-base-uncased WordPiece vocabulary, byte-identical to
Sources/WaxBertTokenizer/Resources/bert_tokenizer_vocab.txt, so no new vocab ships.

Requirements:
    transformers>=4.44,<5.0 torch>=2.5,<2.8 coremltools>=8.0 numpy

Usage:
    python -I scripts/convert_e5_small_v2.py
    WAX_TEST_E5=1 swift test --traits E5Embeddings --filter WaxE5Tests

Output:
    Sources/WaxVectorSearchE5/Resources/e5-small-v2.mlmodelc
"""

import os
import shutil
import subprocess
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from transformers import AutoModel, AutoTokenizer

MODEL_NAME = "intfloat/e5-small-v2"
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources",
    "WaxVectorSearchE5",
    "Resources",
)
MLPACKAGE_PATH = os.path.join(OUTPUT_DIR, "e5-small-v2.mlpackage")
MLMODELC_PATH = os.path.join(OUTPUT_DIR, "e5-small-v2.mlmodelc")

# Must match E5Embeddings.sequenceLengthBuckets.
MIN_SEQUENCE_LENGTH = 32
MAX_SEQUENCE_LENGTH = 512
# Must match E5Embedder.maximumCoreMLPredictionBatchSize.
MAX_BATCH_SIZE = 64

# Finite additive mask fill, representable in Float16 (max ~6.5e4).
MASK_FILL = -1.0e4


class E5EmbedWrapper(nn.Module):
    """Runs the encoder, mean-pools over the attention mask, and L2-normalizes."""

    def __init__(self, hf_model: nn.Module) -> None:
        super().__init__()
        self.model = hf_model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        mask = attention_mask.to(torch.float32)
        additive = (1.0 - mask[:, None, None, :]) * MASK_FILL
        hidden = self.model.embeddings(input_ids=input_ids)
        outputs = self.model.encoder(hidden, attention_mask=additive)
        hidden_state = outputs[0] if isinstance(outputs, tuple) else outputs.last_hidden_state
        summed = (hidden_state * mask[:, :, None]).sum(dim=1)
        count = mask.sum(dim=1, keepdim=True).clamp(min=1e-9)
        pooled = summed / count
        norm = torch.norm(pooled, p=2, dim=1, keepdim=True).clamp(min=1e-12)
        return pooled / norm


def compiled_size_mb(path: str) -> float:
    total = sum(
        os.path.getsize(os.path.join(directory, name))
        for directory, _, files in os.walk(path)
        for name in files
    )
    return total / (1024 * 1024)


def convert() -> None:
    print(f"Loading model: {MODEL_NAME}")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    hf_model = AutoModel.from_pretrained(MODEL_NAME, attn_implementation="eager", torchscript=True)
    hf_model.eval()

    wrapper = E5EmbedWrapper(hf_model).eval()
    dummy_ids = torch.randint(0, tokenizer.vocab_size, (1, MIN_SEQUENCE_LENGTH), dtype=torch.int32)
    dummy_mask = torch.ones(1, MIN_SEQUENCE_LENGTH, dtype=torch.int32)

    print("Tracing model...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask))

    batch_dim = ct.RangeDim(lower_bound=1, upper_bound=MAX_BATCH_SIZE, default=1)
    sequence_dim = ct.RangeDim(
        lower_bound=MIN_SEQUENCE_LENGTH, upper_bound=MAX_SEQUENCE_LENGTH, default=MIN_SEQUENCE_LENGTH
    )

    print("Converting to CoreML (FP16 compute)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=ct.Shape(shape=[batch_dim, sequence_dim]), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=ct.Shape(shape=[batch_dim, sequence_dim]), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embeddings", dtype=np.float32)],
        convert_to="mlprogram",
        # FP16 compute halves CPU embedding time (LongMemEval ingest 988 to 471 CPU s) with
        # the same retrieval (R_all@5 0.905 both). The finite MASK_FILL keeps padded rows
        # out of FP16 overflow.
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )

    print("Compressing weights to INT8 (per-channel symmetric)...")
    op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype=np.int8,
        granularity="per_channel",
    )
    config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
    mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)

    mlmodel.author = "Wax"
    mlmodel.license = "MIT (intfloat/e5-small-v2)"
    mlmodel.short_description = (
        "intfloat/e5-small-v2 (384-dim, INT8 weights, FP16 compute). "
        "Masked mean pooling + L2 normalization baked in. No query/passage prefixes."
    )
    mlmodel.version = "1.0"

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    if os.path.exists(MLPACKAGE_PATH):
        shutil.rmtree(MLPACKAGE_PATH)
    print(f"Saving mlpackage to: {MLPACKAGE_PATH}")
    mlmodel.save(MLPACKAGE_PATH)

    if os.path.exists(MLMODELC_PATH):
        shutil.rmtree(MLMODELC_PATH)
    print(f"Compiling to mlmodelc: {MLMODELC_PATH}")
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", MLPACKAGE_PATH, OUTPUT_DIR],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Compilation failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    if os.path.exists(MLPACKAGE_PATH):
        shutil.rmtree(MLPACKAGE_PATH)

    if not os.path.exists(MLMODELC_PATH):
        print("Error: .mlmodelc not found after compilation", file=sys.stderr)
        sys.exit(1)
    print(f"Success! Model compiled to {MLMODELC_PATH} ({compiled_size_mb(MLMODELC_PATH):.1f} MB)")


if __name__ == "__main__":
    convert()
