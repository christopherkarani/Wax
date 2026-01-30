Prompt:
You are the plan author. Produce a detailed, ordered optimization plan that targets step-function performance gains on-device.

Goal:
Provide a deterministic plan with explicit files, APIs, data structures, and benchmark gates. Focus on algorithms and architecture over micro-optimizations, but list micro opportunities.

Context:
- Benchmark ground truth: `PerfAudit/Raw/bench_2026-01-30_full.log`.
- I/O benchmarks: `PerfAudit/Raw/IOBenchmarks_2026-01-30.log`.
- Core bottlenecks: MiniLM cold start + lack of true batching, ingest scaling, memory peaks, vector engine selection.
- Relevant code:
  - MiniLM: `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift`, `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift`
  - Vector search: `Sources/WaxVectorSearch/MetalVectorEngine.swift`, `Sources/WaxVectorSearch/USearchVectorEngine.swift`
  - Text search: `Sources/WaxTextSearch/FTS5Serializer.swift`, `Sources/WaxTextSearch/FTS5SearchEngine.swift`
  - WAL/commit: `Sources/WaxCore/Wax.swift`

Deliverable:
- A step-by-step plan with phases, each step listing:
  - File(s) and symbol(s) to change
  - Precise change description
  - Benchmark gate (metric + target)
  - Risk and rollback notes
