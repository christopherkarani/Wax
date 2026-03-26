# Benchmark Workflow

Use this guide when a Wax change needs evidence from a benchmark run.

## Start Here

Choose the narrowest test that reproduces the symptom.

- `RememberDedupBenchmarks` for ingest dedup, RSS growth, and memory retention
- `StoreBloatBenchmarks` for dead payload growth and close-time rewrite behavior
- `SessionRuntimeStatsBenchmarks` for runtime accounting and per-session overhead
- `WALCompactionBenchmarks` for write amplification, reopen cost, and compaction pressure
- `RAGBenchmarks` and `RAGBenchmarksMiniLM` for retrieval and embedding regressions
- `HandoffLookupBenchmarks` for lookup latency under load
- `PayloadLivenessBenchmarks` and `SurrogateSourceBenchmarks` for file growth and maintenance effects
- `AccessStatsBootstrapBenchmarks` for initialization overhead
- `ArcticPerformanceBenchmark` for Arctic embedder and CoreML path checks
- `RAGBenchmarkSupport.swift` for scale selection, deterministic embeddings, and async XCTest measurement plumbing

## Common Commands

Use the benchmark file itself when it exposes a single gated test, or filter XCTest directly.

```bash
WAX_BENCHMARK_REMEMBER_DEDUP=1 swift test --filter RememberDedupBenchmarks
WAX_BENCHMARK_STORE_BLOAT=1 swift test --filter StoreBloatBenchmarks
WAX_BENCHMARK_METRICS=1 swift test --filter SessionRuntimeStatsBenchmarks
WAX_BENCHMARK_METAL=1 swift test --filter ArcticPerformanceBenchmark
```

If the suite is noisy, rerun with the same inputs before changing code.

## Benchmark Flags

| Flag | Use |
|---|---|
| `WAX_RUN_XCTEST_BENCHMARKS=1` | Core RAG performance suite |
| `WAX_BENCHMARK_MINILM=1` | MiniLM embedding benchmarks |
| `WAX_BENCHMARK_METAL=1` | Metal vector engine benchmarks |
| `WAX_BENCHMARK_OPTIMIZATION=1` | Actor hop and batching comparisons |
| `WAX_BENCHMARK_WAL_COMPACTION=1` | WAL compaction workloads |
| `WAX_BENCHMARK_WAL_GUARDRAILS=1` | WAL pressure guardrails |
| `WAX_BENCHMARK_WAL_REOPEN_GUARDRAILS=1` | WAL replay and reopen guardrails |
| `WAX_BENCHMARK_SAMPLES=1` | p50/p95/p99 sampled latency runs |
| `WAX_BENCHMARK_COLD_OPEN=1` | Cold-open search benchmark |
| `WAX_BENCHMARK_10K=1` | 10K document scale runs |
| `WAX_BENCHMARK_METRICS=1` | CPU and memory metric collection |
| `WAX_BENCHMARK_LONG_MEMORY=1` | Long-memory recall quality harness |
| `WAX_BENCHMARK_SCALE=smoke|standard` | Control dataset size for gated tests |
| `WAX_BENCHMARK_DOCS`, `WAX_BENCHMARK_SENTENCES`, `WAX_BENCHMARK_DIMS`, `WAX_BENCHMARK_TOPK`, `WAX_BENCHMARK_ITERS` | Fine-grained benchmark scaling knobs used by the shared harness |
| `WAX_BENCHMARK_MINILM_TIMEOUT_SECS` | Override MiniLM benchmark timeout when the harness needs more slack |
| `WAX_BENCHMARK_ACCESS_STATS_BOOTSTRAP`, `WAX_BENCHMARK_REMEMBER_DEDUP`, `WAX_BENCHMARK_STORE_BLOAT`, `WAX_BENCHMARK_SESSION_STATS`, `WAX_BENCHMARK_HANDOFF_LOOKUP`, `WAX_BENCHMARK_SURROGATE_SOURCES`, `WAX_BENCHMARK_PAYLOAD_LIVENESS`, `WAX_BENCHMARK_ARCTIC` | Narrower regression lanes with dedicated harnesses |

Repo-specific benchmarks may add their own inputs, such as:

- `WAX_REMEMBER_DEDUP_*`
- `WAX_BENCHMARK_STORE_BLOAT_OUTPUT`
- `WAX_BENCHMARK_REMEMBER_DEDUP_OUTPUT`

## What To Capture

For CPU regressions:

- wall-clock time
- sample count
- p50, p95, and p99 if available

For memory regressions:

- RSS before, peak, and after
- allocated bytes
- dead payload bytes
- dead payload fraction
- TOC size and frame count

For file-growth regressions:

- logical bytes
- allocated bytes
- segment catalog size
- frame count

## False Positives

- Do not trust a single run when caches are cold.
- Do not compare different scale settings.
- Do not compare runs with different CoreML compute units or background compiler activity.
- Do not treat sampled latency as stable if the benchmark has very few samples.
- Do not infer a memory leak from RSS alone; compare store metrics and file growth too.
- Do not treat `DispatchSemaphore + Task` inside the shared XCTest measurement helper as a production scheduling bug.
- Do not attribute ANE/GPU jitter to the code path until you have ruled out background compiler activity and compute-unit changes.

## Where The Time Usually Goes

- `Sources/WaxCore/Wax.swift`
- `Sources/WaxCLI/StoreSession.swift`
- `Sources/WaxVectorSearch/MiniLMEmbedder.swift`
- `Sources/WaxVectorSearch/MetalVectorEngine.swift`
- `Sources/Wax/RAG/TokenCounter.swift`
- `Sources/WaxTextSearch/FTS5SearchEngine.swift`
- `Sources/WaxCore/Concurrency/*`
- `Tests/WaxIntegrationTests/RAGBenchmarkSupport.swift`
- `Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift`
