Prompt:
You are a Swift + systems performance engineer specializing in ANN indexes (HNSW/USearch). You will audit Wax's CPU vector search engine implementation for algorithmic and implementation bottlenecks, and propose step-function improvements that are compatible with on-device constraints.

Goal:
Produce a diagnosis + fix list focused on `USearchVectorEngine` + vec index persistence + ingest/search scaling behavior.

Task BreakDown:
1) Read the implementation
   - `Sources/WaxVectorSearch/USearchVectorEngine.swift`
   - `Sources/WaxVectorSearch/VectorSerializer.swift`
   - `Sources/Wax/UnifiedSearch/UnifiedSearchEngineCache.swift` (vector engine caching + pending embeddings)
   - `Sources/Wax/VectorSearchSession.swift` (engine selection + put/search APIs)

2) Identify bottlenecks (be specific)
   - Actor isolation vs additional `AsyncMutex` usage: where it helps correctness vs where it adds contention.
   - I/O executor overhead: how many crossings into `BlockingIOExecutor` per operation; identify batching opportunities.
   - Ingest path:
     - Per-vector `remove(key:)` then `add(key:)` strategy: cost and alternatives.
     - Reserve strategy: capacity growth; effect on large ingests.
   - Search path:
     - USearch query call frequency and bridging overhead.
     - TopK and score mapping overhead.
   - Persistence:
     - Buffer serialization/deserialization; cost drivers; any extra copies.
     - Compatibility with Metal encoding: current `metal -> usearch` conversion path complexity/cost.

3) Algorithmic limits vs implementation limits
   - State what is inherent to HNSW/USearch (e.g., build/search complexity) vs what is Wax-specific overhead (actor hops, copying, reserve patterns).

4) Propose high-impact fixes
   - Must include: what to change, where (file + function), why it works, and expected impact.
   - Include at least one "step-function" option (e.g., quantization, graph tuning, hierarchical caching, multi-index sharding).
   - Include micro-optimizations only as a separate section.

5) Benchmark coverage gaps
   - List missing benchmarks for vector ingest/search scaling (e.g., N=1k/10k/100k/1M, dims=384, topK=10/50/200) and persistence costs (serialize+commit).

Deliverable:
- A markdown write-up with:
  - Bottlenecks (ranked)
  - Fix proposals (ranked)
  - Benchmark additions
