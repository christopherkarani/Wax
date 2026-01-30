Prompt:
You are a Metal/accelerated-vector-search specialist. Evaluate Wax’s Metal vs USearch scaling and identify when GPU is beneficial or harmful.

Goal:
Recommend a deterministic engine-selection strategy and GPU/CPU work split for vector search scaling.

Context:
- Metal search latency at scale (debug run, Jan 30 2026):
  - Metal 10k: 0.0005 s; 50k: 0.0018 s; 100k: 0.0034 s
  - USearch 10k: 0.0003 s; 50k: 0.0001 s; 100k: 0.0002 s
  - Source: `PerfAudit/Raw/bench_2026-01-30_full.log:314-323`.
- Metal ingest scaling (addBatch): 10k 0.1619 s; 50k 0.7529 s; 100k 1.2777 s
  - Source: `PerfAudit/Raw/bench_2026-01-30_full.log:295-312`.
- Metal engine implementation: `Sources/WaxVectorSearch/MetalVectorEngine.swift` (search, GPU sync, buffers).

Deliverable:
- A scaling-based decision rule (N, dims, topK) for Metal vs USearch.
- Specific API/structure changes (files + symbols).
- Expected speedups and risks (power, memory bandwidth, queue contention).
