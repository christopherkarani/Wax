# Core ML Model Optimization Guide

This document details the process for converting the `all-MiniLM-L6-v2` transformer model to Core ML with **dynamic batching support**. 

This optimization is required to unlock hardware acceleration (ANE/GPU) for batched embeddings, providing a theoretical 5-10x throughput increase over the current serial execution.

## The Bottleneck
The current model was exported with a fixed input shape of `(1, 512)`. When the application requests a batch of 32 embeddings:
1. Core ML unrolls this into 32 separate inference calls.
2. The ANE/GPU must context-switch for every single document.
3. Throughput is capped by CPU overhead and latency, not compute power.

## The Solution: `RangeDim`
By defining the batch dimension as a `ct.RangeDim(1, 64)`, we tell the Core ML compiler to generate a model that accepts a tensor of shape `(N, 512)`. This allows the hardware to process `N` documents in a single parallel operation.

## Prerequisites

You need a Python environment with the following packages:

```bash
pip install torch transformers coremltools
```

## Conversion Script

A script has been created at `scripts/convert_model.py`.

### Key Features of the Script:
1. **`ct.RangeDim`**: Defines the batch size as flexible (1 to 64).
2. **`convert_to="mlprogram"`**: Uses the modern format required for efficient float16 execution on Apple Silicon.
3. **`compute_precision=ct.precision.FLOAT16`**: Halves memory bandwidth usage and doubles potential ANE throughput without significant accuracy loss for embeddings.

## Running the Conversion

1. Run the script:
   ```bash
   python3 scripts/convert_model.py
   ```

2. Locate the output:
   The script will generate `all-MiniLM-L6-v2.mlpackage` in the current directory.

3. Integration:
   Replace the existing model in the source tree:
   ```bash
   rm -rf Sources/WaxVectorSearchMiniLM/Resources/all-MiniLM-L6-v2.mlpackage
   mv all-MiniLM-L6-v2.mlpackage Sources/WaxVectorSearchMiniLM/Resources/
   ```

4. **Verify**:
   Run the `BatchEmbeddingBenchmark` again. You should see the speedup jump from ~1.15x to significant multiples (depending on hardware).
