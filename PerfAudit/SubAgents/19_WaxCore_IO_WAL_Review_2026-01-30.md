Prompt:
You are a storage/WAL performance specialist. Audit Wax commit/IO path and identify throughput bottlenecks or crash-safety tradeoffs.

Goal:
Map WAL/commit costs to WaxCore implementation and propose safe, measurable improvements.

Context:
- Commit path: `Sources/WaxCore/Wax.swift:846-930`.
- WAL benchmark (debug run, Jan 30 2026):
  - wal_put_1000 mean 0.2306 s; wal_commit_1000 mean 0.0189 s
  - `PerfAudit/Raw/IOBenchmarks_2026-01-30.log:5-6`.

Deliverable:
- Identify hot spots in commit/IO flow.
- Propose changes that preserve crash safety.
- Expected impact on ingest throughput.
