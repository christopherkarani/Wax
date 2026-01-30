Prompt:
You are a vector index performance engineer (HNSW/USearch). Audit Wax’s USearch path and propose step-function improvements.

Goal:
Identify algorithmic vs implementation bottlenecks in USearch vector ingest/search/serialization and propose fixes.

Task BreakDown:
1) Read code:
   - `Sources/WaxVectorSearch/USearchVectorEngine.swift`
   - `Sources/WaxVectorSearch/VectorSerializer.swift`
   - `Sources/Wax/VectorSearchSession.swift`
2) Correlate with benchmarks:
   - `PerfAudit/Raw/BufferSerializationBenchmark.log`
   - `PerfAudit/Raw/RAGPerformanceBenchmarks_10k.log` (ingest scaling)
3) Diagnose:
   - per-vector `remove` + `add` in addBatch
   - BlockingIOExecutor crossings
   - quantization support and index parameters (connectivity)
4) Propose fixes:
   - quantization (f16/i8) + recall tradeoffs
   - sharding / multi-index
   - bulk insert and reserve strategies

Deliverable:
- Markdown report with bottlenecks + fixes + benchmark additions.
