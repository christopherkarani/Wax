Prompt:
Expand and run benchmarks for batch embeddings, dynamic batching, and Core ML path changes, then conduct a formal code review against the plan and tests.

Goal:
Benchmark evidence that dynamic batching and caching improve throughput without regressions, plus an independent code review that verifies plan alignment and completeness.

Task BreakDown:
- Update or add benchmarks in `Tests/WaxIntegrationTests/BatchEmbeddingBenchmark.swift` to capture batch size scaling and cache hit rates.
- Add a benchmark path that uses the new .mlmodelc resource (Core ML dynamic batch) and compares against the prior sequential path.
- Record baseline and post-change numbers (throughput, latency, memory) and document them in a short report.
- Perform a code review with a dedicated reviewer against the plan + tests; list any gaps and propose follow-up tasks.
- Gate merges on benchmark delta thresholds and reviewer signoff.
