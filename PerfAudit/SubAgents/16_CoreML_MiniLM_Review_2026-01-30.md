Prompt:
You are a Core ML performance specialist. Audit Wax’s MiniLM embedding path for cold start and throughput. Provide concrete, file-referenced findings and fix proposals.

Goal:
Identify the concrete causes of MiniLM cold-start latency and the lack of true batch speedup, then propose deterministic, on-device-safe fixes with expected impact.

Context:
- MiniLM model load falls back to runtime compilation if `.mlmodelc` is missing: `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:96-133`.
- Batch embedding uses `model.predictions(inputs:)` over per-input `MLMultiArray` rather than a single batched tensor: `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:40-65`.
- Batch embedding entry point in embedder: `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift:95-124`.
- Benchmarks (debug run, Jan 30 2026):
  - `minilm_cold_start` mean 3.3073 s: `PerfAudit/Raw/bench_2026-01-30_full.log:250`.
  - Batch vs sequential speedup only 1.02x: `PerfAudit/Raw/bench_2026-01-30_full.log:137-146`.

Deliverable:
- Root-cause analysis tied to file references.
- A short list of concrete code changes (files + functions).
- Expected performance deltas (cold start, batch throughput).
- Risks/tradeoffs for on-device constraints (ANE/GPU/memory).
