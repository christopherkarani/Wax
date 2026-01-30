Prompt:
You are a storage + SQLite performance engineer. Audit Wax’s text search (FTS5) and WAL/IO open paths for latency and memory usage.

Goal:
Find cold-open and ingest bottlenecks in FTS5, especially deserialize and transaction batching.

Task BreakDown:
1) Read code:
   - `Sources/WaxTextSearch/FTS5Serializer.swift` (deserialize vs deserializeReadOnly)
   - `Sources/WaxTextSearch/FTS5SearchEngine.swift` (flush threshold, batch ops)
   - `Sources/Wax/UnifiedSearch/UnifiedSearchEngineCache.swift` (read-only mapped open)
2) Correlate with benchmarks:
   - `PerfAudit/Raw/RAGPerformanceBenchmarks_*` (cold_open_hybrid)
   - `PerfAudit/Raw/UnifiedSearchHybrid_with_metrics.log` (memory)
3) Diagnose:
   - staged vs committed open path copies
   - transaction batching vs flushThreshold
4) Propose fixes:
   - mmap-based open for staged path where safe
   - alternative FTS5 pragma tuning
   - WAL/IO coalescing

Deliverable:
- Markdown report with bottlenecks + fixes + benchmark additions.
