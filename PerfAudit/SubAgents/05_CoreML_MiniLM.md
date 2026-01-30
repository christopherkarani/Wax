Prompt:
You are a Core ML + on-device performance engineer. Audit Wax's MiniLM embedder and tokenizer for throughput/latency and propose changes that yield step-function improvements on-device (ANE/GPU utilization, batching, memory reuse).

Goal:
Produce a concrete, implementable plan to improve query-time and ingest-time embedding performance and reduce memory/power overhead.

Task BreakDown:
1) Read implementation
   - `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift`
   - `Sources/WaxVectorSearchMiniLM/CoreML/*` (tokenizer + model wrapper)
   - Benchmarks: `Tests/WaxIntegrationTests/RAGBenchmarksMiniLM.swift`, `BatchEmbeddingBenchmark.swift`, `TokenizerBenchmark.swift`

2) Identify bottlenecks
   - Tokenization:
     - allocations, string/utf8 conversions, vocab lookup, attention mask construction.
   - CoreML inference:
     - model load/cold start path; compute unit selection; batch vs sequential predictions.
     - MLMultiArray allocations and copying.
   - Embedding post-processing:
     - pooling strategy, normalization, copies.

3) High-impact fixes
   - Must include specific APIs:
     - `MLModelConfiguration.computeUnits`
     - batch prediction APIs (`MLBatchProvider` / `prediction(fromBatch:)`) where applicable
     - `MLShapedArray` usage and preallocation
   - Include at least one step-function option:
     - fused tokenizer+packing, static buffer reuse, persistent model instance pool, or pre-tokenized chunk caching.

4) Benchmark coverage gaps
   - Add benchmarks to separate:
     - tokenizer-only
     - model-only (pre-tokenized inputs)
     - end-to-end embed
     - batch scaling curves (already present, extend as needed)

Deliverable:
- Markdown write-up with ranked bottlenecks + fixes + benchmark additions; include expected speedups based on known CoreML behavior (qualitative is ok, but be explicit about assumptions).
