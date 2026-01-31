# Core ML Model Optimization Guide

This document details the process for converting the `all-MiniLM-L6-v2` transformer model to Core ML with **dynamic batch + sequence length** support and shipping a compiled `.mlmodelc`.

This optimization is required to unlock hardware acceleration (ANE/GPU) for batched embeddings, providing a theoretical 5-10x throughput increase over the current serial execution.

## The Bottleneck
The current model was exported with a fixed input shape of `(1, 512)`. When the application requests a batch of 32 embeddings:
1. Core ML unrolls this into 32 separate inference calls.
2. The ANE/GPU must context-switch for every single document.
3. Throughput is capped by CPU overhead and latency, not compute power.

## The Solution: `RangeDim`
By defining the batch dimension as a `ct.RangeDim(1, 64)` and the sequence length as a `ct.RangeDim(8, 512)`, we tell the Core ML compiler to generate a model that accepts tensors of shape `(N, L)`. This allows the hardware to process `N` documents in a single parallel operation while avoiding unnecessary compute for short inputs.

## Prerequisites

You need a Python environment with the following packages:

```bash
pip install torch==2.7.* transformers==4.37.* coremltools==9.0
```

Optional (required only for k-means palettization):
```bash
pip install scikit-learn
```

## Conversion Script

A script has been created at `scripts/convert_model.py`.

### Key Features of the Script:
1. **`ct.RangeDim`**: Defines dynamic batch and sequence length ranges.
2. **`convert_to="mlprogram"`**: Uses the modern format required for efficient float16 execution on Apple Silicon.
3. **`compute_precision=ct.precision.FLOAT16`**: Halves memory bandwidth usage and doubles potential ANE throughput without significant accuracy loss for embeddings.
4. **Optional quantization**: `--quantize int8|int4` for smaller models (validate quality before shipping).
5. **Optional palettization**: `--palettize-nbits 4` for additional compression (k-means needs scikit-learn).
6. **Optional activation quantization (W8A8)**: `--activation-quantize --quantize int8` with calibration data.

## Running the Conversion

1. Run the script (dynamic batch + sequence length). Use EnumeratedShapes for best performance on ANE/GPU (requires macOS 15 / iOS 18 or later):
   ```bash
   python3 scripts/convert_model.py --enumerated-shapes
   ```

   If SDPA conversion is supported on your toolchain, try:
   ```bash
   python3 scripts/convert_model.py --enumerated-shapes --attn-implementation sdpa
   ```

2. Optional compression variants (benchmark + validate quality before shipping):
   - **W8 per-channel**:
     ```bash
     python3 scripts/convert_model.py --enumerated-shapes --quantize int8 --quantize-granularity per_channel
     ```
   - **INT4 per-block**:
     ```bash
     python3 scripts/convert_model.py --enumerated-shapes --quantize int4 --quantize-granularity per_block --quantize-block-size 32
     ```
   - **Palettization (uniform, no sklearn)**:
     ```bash
     python3 scripts/convert_model.py --enumerated-shapes --palettize-nbits 4 --palettize-mode uniform --palettize-granularity per_grouped_channel --palettize-group-size 8
     ```
   - **Palettization (k-means)** requires scikit-learn:
     ```bash
     python3 scripts/convert_model.py --enumerated-shapes --palettize-nbits 4 --palettize-mode kmeans --palettize-granularity per_grouped_channel --palettize-group-size 8
     ```
   - **Activation quantization (W8A8)** (requires calibration data and a writable temp dir):
     ```bash
     TMPDIR=/tmp python3 scripts/convert_model.py --enumerated-shapes --activation-quantize --quantize int8 --quantize-granularity per_channel
     ```

2. Locate the output:
   The script will generate `all-MiniLM-L6-v2.mlpackage` in the current directory.

3. Compile to `.mlmodelc`:
   ```bash
   xcrun coremlc compile all-MiniLM-L6-v2.mlpackage /tmp/coreml_out
   ```

4. Integration:
   Replace the existing model in the source tree with the compiled model:
   ```bash
   rm -rf Sources/WaxVectorSearchMiniLM/Resources/all-MiniLM-L6-v2.mlmodelc
   mv /tmp/coreml_out/all-MiniLM-L6-v2.mlmodelc Sources/WaxVectorSearchMiniLM/Resources/
   ```

5. **Verify**:
   Run the `BatchEmbeddingBenchmark` again. You should see the speedup jump from ~1.15x to significant multiples (depending on hardware).

## Notes from Local Benchmarks (M3 Max)
- Weight-only quantization (int8/int4) and uniform palettization did not improve end-to-end benchmarks on an M3 Max in this repo.
- Activation quantization (W8A8) failed in the current environment due to Core ML temp-dir restrictions during calibration.
- Always re-run `BatchEmbeddingBenchmark` and `RAGMiniLMBenchmarks` on target hardware before shipping.
