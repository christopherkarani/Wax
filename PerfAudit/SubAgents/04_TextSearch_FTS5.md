Prompt:
You are a Swift + SQLite/FTS5 performance engineer. Audit Wax's text search subsystem for indexing/search bottlenecks and propose measurable improvements (schema, transactions, serialization, query patterns).

Goal:
Deliver a prioritized list of the dominant text search costs during ingest and recall, with concrete fixes and benchmark additions.

Task BreakDown:
1) Read implementation
   - `Sources/WaxTextSearch/FTS5SearchEngine.swift`
   - Any WaxTextSearch sessions/adapters used by `Wax` / orchestrator
   - `Sources/Wax/UnifiedSearch/UnifiedSearch.swift` (query patterns + fallback query expansion)
   - Benchmarks: `Tests/WaxIntegrationTests/RAGBenchmarks.swift` (text search and unified search tests)

2) Identify bottlenecks
   - Indexing:
     - Per-document vs batched inserts; transaction scope; FTS5 optimize/merge behavior.
     - sqlite3_serialize costs and when they're triggered.
   - Search:
     - Query compilation overhead; snippet extraction; topK behavior.
     - Effects of OR-expanded queries and token quoting (`orExpandedQuery`).
   - Cache behavior:
     - Deserialization in `UnifiedSearchEngineCache` (when it happens, why).

3) Propose improvements
   - Must include: what to change, where, why, expected impact, risks.
   - Include at least one architectural option that gives a step-function improvement (e.g., incremental segment merges, background compaction, avoiding full serialize for small deltas).

4) Benchmark coverage gaps
   - Add benchmarks for:
     - FTS indexing throughput vs doc/chunk count
     - FTS query latency across corpus sizes
     - Serialization/commit costs for lex index

Deliverable:
- Markdown write-up with ranked bottlenecks + fixes + benchmark additions.
