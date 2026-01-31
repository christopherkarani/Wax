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

## Conversion Script

A script has been created at `scripts/convert_model.py`.

### Key Features of the Script:
1. **`ct.RangeDim`**: Defines dynamic batch and sequence length ranges.
2. **`convert_to="mlprogram"`**: Uses the modern format required for efficient float16 execution on Apple Silicon.
3. **`compute_precision=ct.precision.FLOAT16`**: Halves memory bandwidth usage and doubles potential ANE throughput without significant accuracy loss for embeddings.
4. **Optional quantization**: `--quantize int8|int4` for smaller models (validate quality before shipping).

## Running the Conversion

1. Run the script (dynamic batch + sequence length). Use EnumeratedShapes for best performance on ANE/GPU (requires macOS 15 / iOS 18 or later):
   ```bash
   python3 scripts/convert_model.py --enumerated-shapes
   ```

   If SDPA conversion is supported on your toolchain, try:
   ```bash
   python3 scripts/convert_model.py --enumerated-shapes --attn-implementation sdpa
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
