# Wax Benchmark Results

> Latest full benchmark report: [2026-03-06 Performance Results](benchmarks/2026-03-06-performance-results.md)
>
> Highlights:
> - Cold open p95: **9.2 ms**
> - Warm hybrid with previews p95 / p99: **6.1 ms / 6.5 ms**
> - MemoryOrchestrator ingest: **0.445 s avg**
> - WAL `large_hybrid_10k` commit p95 / p99: **97.40 ms / 100.30 ms**
>
> This page retains the earlier 2026-03-03 snapshot for historical comparison.

**Date:** 2026-03-03
**Platform:** macOS (Darwin 25.0.0), Apple Silicon
**Build:** Debug (`swift test`)
**Branch:** `feat/wax-v2-improvements`

---

## 1. Metal Vector Engine

| Metric | Value |
|---|---|
| **Search avg** (1K vectors, 128d) | **2.36 ms** |
| Latency per vector | 0.0024 ms |
| **COLD search** (10K vectors, 384d, with GPU sync) | **71.63 ms** |
| **WARM search avg** (no sync) | **1.22 ms** |
| WARM search min / max | 0.85 ms / 2.24 ms |
| Warm search speedup | **58.6x faster** |
| Memory bandwidth saved per warm query | 14.6 MB |

---

## 2. Buffer Serialization

**Config:** 1K vectors, 384 dimensions, 1643 KB serialized size, 5 iterations

| Operation | Buffer | File | Speedup |
|---|---|---|---|
| **SAVE** | 0.189 ms | 22.27 ms | **117.8x** |
| **LOAD** | 0.241 ms | 0.606 ms | **2.5x** |
| **TOTAL** | — | — | **53.1x** |

---

## 3. Batch Embedding (MiniLM)

### Scaling by Batch Size

| Batch Size | ms/text | texts/sec |
|---|---|---|
| 8 | 8.12 | 123.1 |
| 16 | 5.17 | **193.5** |
| 32 | 5.20 | 192.2 |
| 64 | 5.18 | 192.9 |

### Batch vs Sequential (32 texts, 3 iterations)

| Strategy | Total (ms) | Per-text (ms) |
|---|---|---|
| Sequential | 316.9 | 9.90 |
| Batch | 287.0 | 8.97 |
| **Speedup** | **1.10x** | **(9.4% improvement)** |

### Orchestrator Ingest (100 docs, 2 iterations)

| Metric | Value |
|---|---|
| Average time | 1.12 s |
| Throughput | **89.3 docs/sec** |

---

## 4. MiniLM RAG

| Metric | Value |
|---|---|
| Ingest (XCTMetric, 1K docs, 3 samples) | **1.642 s avg** (stdev 4.9%) |
| Cold start | **275 ms** |
| Single embedding | **276 ms** |
| Batch throughput (full scaling suite) | 107.8 s |

---

## 5. RAG Ingest Performance

**Config:** XCTMetric, 1K documents, 5 iterations

| Mode | Avg (s) | Std Dev | Values |
|---|---|---|---|
| Text-only | **0.409** | 31.1% | [0.306, 0.308, 0.605, 0.309, 0.516] |
| Hybrid | **0.616** | 14.6% | [0.715, 0.719, 0.614, 0.516, 0.516] |
| Hybrid Batched | **0.470** | 10.3% | [0.506, 0.517, 0.413, 0.409, 0.507] |

---

## 6. RAG Search Performance

**Config:** XCTMetric, 1K documents, 5 iterations

| Search Type | Avg (s) | Std Dev |
|---|---|---|
| Text (FTS5) | **0.101** | 1.9% |
| Vector (USearch/Metal) | **0.103** | 1.2% |
| Token Counting | **0.101** | 1.9% |
| Orchestrator Recall | **0.103** | 2.5% |

---

## 7. RAG Sampled Latency (Warm)

All values in **milliseconds**.

| Benchmark | mean | p50 | p95 | p99 | min | max | stdev |
|---|---|---|---|---|---|---|---|
| Hybrid Search (Metal + previews) | **5.5** | 5.4 | 5.9 | 6.0 | 5.2 | 6.1 | 0.2 |
| Hybrid Search (Metal, no previews) | **5.5** | 5.5 | 5.8 | 5.9 | 5.1 | 5.9 | 0.2 |
| Hybrid Search (CPU-only) | **5.1** | 5.0 | 5.4 | 5.5 | 4.9 | 5.5 | 0.2 |
| Frame Previews (topK, 512b) | **0.1** | 0.1 | 0.1 | 0.1 | 0.1 | 0.2 | 0.0 |
| Temporal Parsing | **8.0** | 8.0 | 8.3 | 8.3 | 7.7 | 8.3 | 0.1 |
| Stage for Commit (batch64) | **28.9** | 30.3 | 39.4 | 39.6 | 11.1 | 39.6 | 8.1 |
| Commit (batch64) | **15.2** | 14.6 | 18.6 | 19.0 | 10.4 | 19.1 | 2.4 |

### Cold Latency

| Benchmark | mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | stdev (ms) |
|---|---|---|---|---|---|
| **Wax Open/Close** | **1262** | 1262 | 1269 | 1271 | 4.4 |

---

## 8. Tokenizer

**Config:** 1000 iterations, text length 95 chars

| Metric | Value |
|---|---|
| XCTMetric avg | **30 ms** per 1000 tokenizations |
| Per-tokenization | **0.030 ms** |
| Relative std dev | 1.33% |

---

## 9. Optimization Comparison

### Actor vs Task Hop (TokenCounter, 100 texts, 10 iterations)

| Strategy | Avg (ms) |
|---|---|
| Direct Actor | 2.019 |
| Task Hop per call | 2.251 |
| **Speedup** | **1.1x (10.3%)** |

### Metadata Lookup (500 docs, 50 lookups, 10 iterations)

| Strategy | Avg (ms) |
|---|---|
| Batch | 0.050 |
| Sequential | 0.039 |
| Note | Batch benefits increase with larger datasets |

---

## 10. WAL Compaction Workload Matrix

| Workload | Writes | Mode | commit p50 | commit p95 | commit p99 | put p95 | autoCommits | checkpoints | reopen p95 |
|---|---|---|---|---|---|---|---|---|---|
| small_text | 500 | text | **10.4 ms** | 13.5 ms | 14.7 ms | 0.05 ms | 0 | 10 | 1264 ms |
| small_hybrid | 500 | hybrid | **12.3 ms** | 14.0 ms | 14.0 ms | 0.13 ms | 0 | 10 | 1263 ms |
| medium_text | 5,000 | text | **22.3 ms** | 33.4 ms | 35.0 ms | 0.06 ms | 0 | 50 | 1296 ms |
| medium_hybrid | 5,000 | hybrid | **36.0 ms** | 61.2 ms | 63.0 ms | 0.16 ms | 0 | 50 | 1314 ms |
| large_text | 10,000 | text | **34.2 ms** | 61.7 ms | 67.2 ms | 0.09 ms | 0 | 50 | 1319 ms |
| large_hybrid | 10,000 | hybrid | **59.8 ms** | 142.2 ms | 197.1 ms | 0.18 ms | 0 | 50 | 1336 ms |
| sustained_text | 30,000 | text | **166.9 ms** | 166.9 ms | 166.9 ms | 0.57 ms | 31 | 32 | 1387 ms |

---

## 11. Stability (Production Readiness)

| Test | Samples | RSS Growth | p50 Drift | p95 Drift |
|---|---|---|---|---|
| Burn-smoke | 299 | 6.97 MB | 28.7% | 94.0% |
| Soak-smoke | 125 | 0.58 MB | 45.8% | 95.9% |

---

## Known Issues

| Test | Issue | Details |
|---|---|---|
| `testUnifiedSearchHybridPerformance` | Signal 11 (segfault) | Crashes during XCTMetric measurement |
| `testFastRAGBuildPerformanceDenseCached` | Signal 11 (segfault) | Crashes during dense cached RAG build |
| `testTemporalParsingWarmLatencySamples` | Assertion failure | Expected 3000 frames, got 2625 |
| WAL `sustained_write_hybrid` | Disk space exhausted | `pwrite failed: No space left on device` |
| `testBufferSerializationVsFileBased` | Flaky assertion | Load speedup sometimes < 1.0x threshold |

---

## Skipped Benchmarks

The following were not run due to time/resource constraints:

- `testLongMemoryRecallAndAnswerQuality` — requires `WAX_BENCHMARK_LONG_MEMORY=1` (LLM-dependent)
- `testIngestTextOnlyPerformance10KDocs` — requires `WAX_BENCHMARK_10K=1`
- `testIngestHybridPerformance10KDocs` — requires `WAX_BENCHMARK_10K=1`
- `testIngestHybridBatchedPerformance10KDocs` — requires `WAX_BENCHMARK_10K=1`
- `testUnifiedSearchHybridPerformance10KDocs` — requires `WAX_BENCHMARK_10K=1`
- `testUnifiedSearchHybridPerformance10KDocsCPU` — requires `WAX_BENCHMARK_10K=1`
- `testUnifiedSearchHybridPerformanceWithMetrics` — requires `WAX_BENCHMARK_METRICS=1` (CPU/memory metrics)

---

## Environment Variables Reference

| Variable | Enables |
|---|---|
| `WAX_RUN_XCTEST_BENCHMARKS=1` | Core RAG performance benchmarks |
| `WAX_BENCHMARK_MINILM=1` | MiniLM embedding benchmarks |
| `WAX_BENCHMARK_METAL=1` | Metal GPU vector engine benchmarks |
| `WAX_BENCHMARK_OPTIMIZATION=1` | Actor vs task hop, batch vs sequential |
| `WAX_BENCHMARK_WAL_COMPACTION=1` | WAL compaction workload matrix |
| `WAX_BENCHMARK_WAL_GUARDRAILS=1` | Proactive WAL pressure guardrails |
| `WAX_BENCHMARK_WAL_REOPEN_GUARDRAILS=1` | WAL replay snapshot guardrails |
| `WAX_BENCHMARK_SAMPLES=1` | Sampled latency benchmarks (p50/p95/p99) |
| `WAX_BENCHMARK_COLD_OPEN=1` | Cold-open hybrid search benchmark |
| `WAX_BENCHMARK_10K=1` | 10K document scale benchmarks |
| `WAX_BENCHMARK_METRICS=1` | CPU/memory metric collection |
| `WAX_BENCHMARK_LONG_MEMORY=1` | Long-memory recall quality harness |
