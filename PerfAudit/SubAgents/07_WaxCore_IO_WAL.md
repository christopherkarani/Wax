Prompt:
You are a storage systems engineer (Swift + file formats + WAL). Audit WaxCore's I/O, WAL, and commit/flush behavior for performance bottlenecks and propose measurable improvements that preserve crash-safety.

Goal:
Identify the dominant I/O and synchronization costs during ingest and commit, and propose step-function improvements (IO coalescing, reduced fsyncs, better staging/compaction) compatible with on-device constraints.

Task BreakDown:
1) Read implementation
   - `Sources/WaxCore/Wax.swift` (put/putBatch, stage*, commitLocked)
   - WAL: `Sources/WaxCore/WAL/**`
   - File format: `Sources/WaxCore/FileFormat/**`
   - Any IO helpers: `BlockingIOExecutor`, `FDFile`, `FileLock`
   - Relevant tests: `Tests/WaxCoreTests/**` + integration tests touching commit/compaction

2) Identify bottlenecks
   - Fsync frequency and placement (commit path has multiple fsync points).
   - WAL append behavior and fsync policy impact.
   - Data layout and file growth (append-only segments); compaction triggers and costs.
   - Metadata lookup patterns (`frameMetas`, `frameMeta`, previews) and any N+1 patterns.

3) Propose improvements
   - Must separate:
     - safe-by-default changes (no file format changes)
     - file format/WAL changes (require updated invariants + tests)
   - Include at least one step-function option:
     - e.g., segment-level compression + memory-mapped reads, incremental index delta segments, or a redesigned commit protocol that reduces syncs while preserving durability contracts.

4) Benchmark gaps
   - Add benchmarks for:
     - commit latency vs pending mutations
     - open() cold start vs file size
     - WAL recovery time
     - compaction cost and its effect on query latency

Deliverable:
- Markdown write-up with ranked bottlenecks + fixes + benchmark additions + risk analysis (crash safety).
