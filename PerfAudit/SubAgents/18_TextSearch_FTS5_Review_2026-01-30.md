Prompt:
You are a text-search/SQLite performance specialist. Audit Wax FTS5 deserialization and read-only search path for memory and cold-open cost.

Goal:
Verify the current copy-vs-mmap deserialize behavior and recommend a no-copy read-only pipeline that scales to large corpora.

Context:
- Copying deserialize path: `Sources/WaxTextSearch/FTS5Serializer.swift:24-48`.
- Read-only mmap deserialize path: `Sources/WaxTextSearch/FTS5Serializer.swift:55-75`.
- FTS deserialize benchmark (debug run, Jan 30 2026):
  - copy: 0.00079 s; mmap: 0.00026 s
  - `PerfAudit/Raw/IOBenchmarks_2026-01-30.log:1-4`.
- Unified search memory peak ~200,887 kB:
  - `PerfAudit/Raw/bench_2026-01-30_full.log:108`.

Deliverable:
- Concrete diagnosis of copy/mmap costs.
- A plan for enforcing mmap-only on read-only search (files + APIs).
- Expected memory/latency impact and any SQLite constraints.
