# Wax RAG Performance Baseline (Bench Ground Truth)

Date: 2026-01-30

This report is extracted from `PerfAudit/Raw/*.log` and treated as ground truth.

## Benchmark Commands (reference)

```sh
# Standard-scale benchmark suite
swift test --configuration release --filter RAGPerformanceBenchmarks

# Stress scale
WAX_BENCHMARK_SCALE=stress swift test --configuration release --filter RAGPerformanceBenchmarks

# 10k doc tests
WAX_BENCHMARK_10K=1 swift test --configuration release --filter RAGPerformanceBenchmarks

# UnifiedSearch CPU/memory metrics
WAX_BENCHMARK_METRICS=1 swift test --configuration release --filter testUnifiedSearchHybridPerformanceWithMetrics

# MiniLM embedder benches
WAX_BENCHMARK_MINILM=1 swift test --configuration release --filter RAGMiniLMBenchmarks
WAX_BENCHMARK_MINILM=1 swift test --configuration release --filter BatchEmbeddingBenchmark
WAX_BENCHMARK_MINILM=1 swift test --configuration release --filter TokenizerBenchmark

# Metal vector search benches
WAX_BENCHMARK_METAL=1 swift test --configuration release --filter MetalVectorEngineBenchmark

# Serialization + misc comparisons
swift test --configuration release --filter BufferSerializationBenchmark
swift test --configuration release --filter OptimizationComparisonBenchmark
```

## Key Results (Most Load-Bearing)

### CoreML MiniLM (dominant RAG cost)

Source: `PerfAudit/Raw/RAGMiniLMBenchmarks_standard.log`

- `minilm_cold_start`: mean **3.1726 s**
- `minilm_embed`: mean **9.8 ms** (per embed)

Source: `PerfAudit/Raw/BatchEmbeddingBenchmark.log`

- Batch scaling (total / per text / throughput):
  - Batch 8: **70.9 ms / 8.86 ms/text / 112.9 texts/sec**
  - Batch 16: **138.5 ms / 8.66 ms/text / 115.5 texts/sec**
  - Batch 32: **281.8 ms / 8.81 ms/text / 113.6 texts/sec**
  - Batch 64: **567.5 ms / 8.87 ms/text / 112.8 texts/sec**
- Batch vs sequential (32 texts): **1.06x** speedup (9.76 -> 9.19 ms/text)
- Orchestrator ingest (100 docs): **71.9 docs/sec** (avg **1.39 s**)

### Metal vector search (query path)

Source: `PerfAudit/Raw/MetalVectorEngineBenchmark.log`

- 10k vectors, 384 dims, topK=24:
  - Cold (GPU sync): **4.27 ms**
  - Warm (no sync): **0.58 ms avg** (**7.3x** speedup)
  - Bandwidth saved: **14.6 MB per warm query**
- 1k vectors, 128 dims, topK=24: **0.27 ms avg**

### Hybrid search cold-open (open + search)

Source: `PerfAudit/Raw/RAGPerformanceBenchmarks_*.log`

- Smoke (200 docs): **3.4 ms** mean (`cold_open_hybrid`)
- Standard (1k docs): **11.6 ms** mean
- Stress (5k docs): **54.3 ms** mean

### Tokenizer cold start (tiktoken)

Source: `PerfAudit/Raw/RAGPerformanceBenchmarks_*.log`

- `tokenizer_cold_start`: **~10.6–15.0 ms** mean (scale-dependent)

### 10k ingest scaling (index + IO)

Source: `PerfAudit/Raw/RAGPerformanceBenchmarks_10k.log`

- Text-only ingest 10k: **1.029 s** avg
- Hybrid ingest 10k: **1.637 s** avg
- Hybrid batched ingest 10k: **0.724 s** avg

### Unified search CPU/memory metrics

Source: `PerfAudit/Raw/UnifiedSearchHybrid_with_metrics.log`

- Wall clock: **0.103 s** avg (NOTE: harness floor; see below)
- CPU time: **0.012 s** avg
- Peak physical memory: **~22 MB** avg (22660 kB)

### USearch serialization (buffer vs file)

Source: `PerfAudit/Raw/BufferSerializationBenchmark.log`

- SAVE: **0.146 ms** buffer vs **1.901 ms** file (**13.0x**)
- LOAD: **0.195 ms** buffer vs **0.875 ms** file (**4.5x**)
- TOTAL: **8.1x** faster

### Concurrency overhead (actor hop)

Source: `PerfAudit/Raw/OptimizationComparisonBenchmark.log`

- TokenCounter direct actor call: **0.926 ms** avg
- TokenCounter per-call task hop: **1.121 ms** avg (**1.2x** slower)

## Harness-Limited Measurements (Important Caveat)

Many `measureAsync` results cluster around **~0.103 s** in `RAGPerformanceBenchmarks_*`.
These should be treated as **“XCTest harness floor”** for sub-10ms operations.

Action item: add `timedSamples` microbenchmarks for:
- text search
- vector search
- unified search
- FastRAG build variants

