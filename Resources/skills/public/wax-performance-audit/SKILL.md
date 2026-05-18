---
name: wax-performance-audit
description: Benchmarking and performance auditing for the Wax repo. Use when running or interpreting Wax benchmarks, diagnosing CPU, memory, or I/O bottlenecks, or investigating Swift 6.2 concurrency issues such as Sendable, actor isolation, `@unchecked Sendable`, task-group fan-out, and data races.
---

# Wax Performance Audit

## Overview

Use this skill to benchmark Wax changes, isolate the hottest code path, and separate real regressions from noisy samples.

The repo builds with Swift 6.1 and `StrictConcurrency` enabled, so audit for Swift 6.2 concurrency risks without assuming 6.2-only language mode.

## Workflow

1. Name the symptom precisely: latency regression, memory growth, file bloat, or Swift concurrency diagnostics.
2. Pick the narrowest benchmark or test file that exercises the path.
3. Run a baseline and candidate with the same environment and scale.
4. Collect wall time plus memory or file-growth metrics when the issue is not purely CPU-bound.
5. Inspect the smallest relevant actor boundary, task group, cache, or I/O path.
6. Report the evidence, the bottleneck, and the smallest safe fix.

## Benchmark Selection

Use [`references/benchmark-workflow.md`](references/benchmark-workflow.md) for the command matrix, environment flags, and benchmark map.

Prefer these repo entry points when they match the symptom:

- `Tests/WaxIntegrationTests/RAGBenchmarkSupport.swift`
- `Tests/WaxIntegrationTests/RememberDedupBenchmarks.swift`
- `Tests/WaxIntegrationTests/StoreBloatBenchmarks.swift`
- `Tests/WaxIntegrationTests/RAGBenchmarks.swift`
- `Tests/WaxIntegrationTests/RAGBenchmarksMiniLM.swift`
- `Tests/WaxIntegrationTests/BatchEmbeddingBenchmark.swift`
- `Tests/WaxIntegrationTests/SessionRuntimeStatsBenchmarks.swift`
- `Tests/WaxIntegrationTests/WALCompactionBenchmarks.swift`
- `Tests/WaxIntegrationTests/HandoffLookupBenchmarks.swift`
- `Tests/WaxIntegrationTests/PayloadLivenessBenchmarks.swift`
- `Tests/WaxIntegrationTests/SurrogateSourceBenchmarks.swift`
- `Tests/WaxIntegrationTests/AccessStatsBootstrapBenchmarks.swift`
- `Tests/WaxIntegrationTests/ConcurrencyStressTests.swift`
- `Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift`
- `Tests/WaxArcticTests/ArcticPerformanceBenchmark.swift`
- `Tests/WaxCoreTests/ReadWriteLockTests.swift`
- `Tests/WaxCoreTests/AsyncMutexTests.swift`

## Bottleneck Triage

- CPU: look for repeated serialization, unnecessary sorting, extra actor hops, and oversized batch work.
- Memory: compare RSS, allocated bytes, dead payload bytes, TOC growth, and frame count.
- I/O: inspect WAL compaction, reopen cost, and close-time rewrite work.
- Embeddings: check compute unit selection, batch sizing, and warmup or prewarm behavior.
- Noise: rerun if caches are cold, an external compiler/service is active, or the benchmark has low sample counts.
- Gated skips: confirm the env flag actually enabled the lane before treating a skip or pass as evidence.
- Harness plumbing: `measureAsync` in `RAGBenchmarkSupport.swift` uses `DispatchSemaphore` plus `Task` because XCTest measurement is synchronous; do not confuse that with production concurrency.
- ANE/GPU: CPU-only benchmark paths are intentional in some suites, and warm p95/p99 values can be noisy when `ANECompilerService` or similar background work is active.

## Swift 6.2 Concurrency

Use [`references/concurrency-checklist.md`](references/concurrency-checklist.md) when the change touches actors, task groups, `Sendable`, or `@unchecked Sendable`.

Default checks:

- Trace every value that crosses an actor boundary.
- Prefer `@Sendable` closures that capture immutable values.
- Treat `@unchecked Sendable` as a deliberate exception, not a default.
- Watch task groups for hidden fan-out that increases memory pressure.
- Keep blocking I/O off actor executors.
- Verify `@MainActor` crossings in UI-adjacent or Photos code.
- Treat `@preconcurrency` interop and `@unchecked Sendable` around CoreML, GRDB, Photos, and tokenizer internals as review hotspots, not automatic bugs.

## Reporting

When you finish, state:

- the benchmark or test you ran,
- the before/after evidence,
- whether the regression was CPU, memory, I/O, or concurrency-related,
- and the exact file or subsystem that caused it.
