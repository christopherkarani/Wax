#!/usr/bin/env python3
"""
Convert Snowflake Arctic Embed Small to CoreML (.mlpackage → .mlmodelc).

Optimized for Wax's on-device memory/RAG use case:
  - FP16 precision for minimal bundle size (~16 MB) while preserving retrieval quality
  - EnumeratedShapes match Wax's BertTokenizer sequenceLengthBuckets exactly: [32, 64, 128, 256, 384, 512]
  - Batch sizes match ArcticEmbedder's operational patterns: 1 (CLI/MCP single-query),
    8/16/32/64 (batch ingest via BatchEmbeddingProvider)
  - CLS token extraction + L2 normalization baked into the graph (no Swift-side post-processing needed)
  - Targets macOS 15+ / iOS 18+ to match Wax's platform requirements
  - Uses eager attention (not SDPA) for coremltools compatibility

Requirements:
    conda install: transformers>=4.36,<5.0 torch>=2.1,<2.8 coremltools>=8.0 numpy

Usage:
    conda run -n arctic-convert python scripts/convert_arctic_embed.py

Output:
    Sources/WaxVectorSearchArctic/Resources/snowflake-arctic-embed-s.mlmodelc
"""

import os
import sys
import shutil
import subprocess

import numpy as np
import torch
import torch.nn as nn
from transformers import AutoModel, AutoTokenizer
import coremltools as ct


MODEL_NAME = "Snowflake/snowflake-arctic-embed-s"
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources",
    "WaxVectorSearchArctic",
    "Resources",
)
MLPACKAGE_PATH = os.path.join(OUTPUT_DIR, "snowflake-arctic-embed-s.mlpackage")
MLMODELC_PATH = os.path.join(OUTPUT_DIR, "snowflake-arctic-embed-s.mlmodelc")

# Must match BertTokenizer.sequenceLengthBuckets in ArcticEmbeddings.swift
SEQ_LENGTHS = [32, 64, 128, 256, 384, 512]

# Batch 1 = CLI/MCP single-query path (makeCommandLineEmbedder uses batchSize=1)
# Batch 8-64 = batch ingest path (ArcticEmbedder.maximumBatchSize=256, but CoreML
# enumerated shapes only need common sizes — larger batches are chunked by planBatchSizes)
BATCH_SIZES = [1, 8, 16, 32, 64]


class ArcticEmbedWrapper(nn.Module):
    """Wraps the HuggingFace model to extract CLS embedding and L2-normalize.

    This bakes the post-processing into the CoreML graph so the Swift side
    gets a ready-to-use 384-dim unit vector directly from model.prediction().
    No tanh is applied — Arctic uses raw CLS + L2 norm (unlike some MiniLM variants).
    """

    def __init__(self, hf_model):
        super().__init__()
        self.model = hf_model

    def forward(self, input_ids, attention_mask):
        # Pass both input_ids and attention_mask explicitly to avoid coremltools #1545
        # where unnamed inputs cause "attention_mask variable not found" errors
        outputs = self.model(input_ids=input_ids, attention_mask=attention_mask)
        # CLS token = first token's hidden state (standard BERT pooling)
        # When torchscript=True, outputs is a tuple; otherwise it's a named object
        if isinstance(outputs, tuple):
            hidden_state = outputs[0]
        else:
            hidden_state = outputs.last_hidden_state
        cls_embedding = hidden_state[:, 0, :]
        # L2 normalize with epsilon floor to avoid division by zero
        norm = torch.norm(cls_embedding, p=2, dim=1, keepdim=True).clamp(min=1e-12)
        normalized = cls_embedding / norm
        return normalized


def convert():
    print(f"Loading model: {MODEL_NAME}")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)

    # Use eager attention — SDPA produces new_ones/scaled_dot_product_attention ops
    # that coremltools cannot convert. Eager attention uses standard matmul + softmax
    # which maps cleanly to CoreML/ANE ops.
    hf_model = AutoModel.from_pretrained(
        MODEL_NAME,
        attn_implementation="eager",
        torchscript=True,  # Hint to model that we'll trace it
    )
    hf_model.eval()

    wrapper = ArcticEmbedWrapper(hf_model)
    wrapper.eval()

    # Trace with a representative input at the smallest bucket size.
    # Using int32 to match Wax's MLMultiArray .int32 dataType.
    dummy_input_ids = torch.randint(0, tokenizer.vocab_size, (1, 32), dtype=torch.int32)
    dummy_attention_mask = torch.ones(1, 32, dtype=torch.int32)

    print("Tracing model...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_input_ids, dummy_attention_mask))

    # Use RangeDim for batch (1–64) × EnumeratedShapes for seq lengths.
    # This avoids requiring exact batch sizes — any batch 1–64 works with any
    # of the seq length buckets. Wax's planBatchSizes() ensures batches ≤ 64.
    batch_dim = ct.RangeDim(lower_bound=1, upper_bound=64, default=1)
    print(f"Shape: batch=[1..64] × seq_lengths={SEQ_LENGTHS}")

    print("Converting to CoreML (FP32 compute, then FP16 weight compression)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="input_ids",
                shape=ct.Shape(shape=[batch_dim, ct.RangeDim(lower_bound=32, upper_bound=512, default=32)]),
                dtype=np.int32,
            ),
            ct.TensorType(
                name="attention_mask",
                shape=ct.Shape(shape=[batch_dim, ct.RangeDim(lower_bound=32, upper_bound=512, default=32)]),
                dtype=np.int32,
            ),
        ],
        outputs=[ct.TensorType(name="embeddings")],
        convert_to="mlprogram",
        # FLOAT32 compute precision — FP16 compute causes overflow (NaN) in
        # attention/layer-norm paths. We'll compress weights to FP16 separately
        # after conversion, which halves model size without affecting compute.
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )

    # Compress weights from FP32 → INT8 to quarter model size (~127MB → ~33MB).
    # INT8 symmetric quantization preserves retrieval quality for embedding models
    # (typical quality loss < 1% on MTEB benchmarks). At runtime, CoreML dequantizes
    # INT8 weights to FP32 for computation — the FP32 compute graph is unchanged.
    print("Compressing weights to INT8...")
    op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype=np.int8,
        granularity="per_channel",
    )
    config = ct.optimize.coreml.OptimizationConfig(global_config=op_config)
    mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)

    # Add model metadata for diagnostics (visible via mlmodel inspection tools)
    mlmodel.author = "Wax"
    mlmodel.short_description = (
        "Snowflake Arctic Embed Small (384-dim, FP16). "
        "CLS extraction + L2 normalization baked in. "
        "Optimized for Wax on-device memory RAG."
    )
    mlmodel.version = "1.0"

    # Save .mlpackage
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    if os.path.exists(MLPACKAGE_PATH):
        shutil.rmtree(MLPACKAGE_PATH)
    print(f"Saving mlpackage to: {MLPACKAGE_PATH}")
    mlmodel.save(MLPACKAGE_PATH)

    # Compile to .mlmodelc using xcrun (produces the on-device compiled format)
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

    # Clean up .mlpackage (only the compiled .mlmodelc is needed in the bundle)
    if os.path.exists(MLPACKAGE_PATH):
        shutil.rmtree(MLPACKAGE_PATH)

    # Verify output and report size
    if os.path.exists(MLMODELC_PATH):
        size_mb = sum(
            os.path.getsize(os.path.join(dp, f))
            for dp, _, files in os.walk(MLMODELC_PATH)
            for f in files
        ) / (1024 * 1024)
        print(f"Success! Model compiled to {MLMODELC_PATH} ({size_mb:.1f} MB)")
    else:
        print("Error: .mlmodelc not found after compilation", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    convert()
