Prompt:
You are a senior Swift performance engineer. Your job is to run Wax's existing benchmarks and extract ground-truth numbers (latency/throughput/CPU/memory) in a reproducible way.

Goal:
Produce a single baseline report (markdown) containing benchmark outputs + a compact table of the key metrics per benchmark and per scale.

Task BreakDown:
1) Toolchain sanity
   - Confirm Swift toolchain is 6.2.x and package builds in Release.
   - Record `swift --version`, machine model, macOS version, and whether Metal is available.

2) Run benchmark suites (Release)
   - RAG + core: `swift test -c release --filter RAGPerformanceBenchmarks`
     - Repeat at scales: `WAX_BENCHMARK_SCALE=smoke|standard|stress`
     - Repeat with metrics: `WAX_BENCHMARK_METRICS=1` (note CPU% + peak memory from XCTest output)
     - Repeat 10K: `WAX_BENCHMARK_10K=1` (note which tests ran and their results)
   - Vector GPU: `WAX_BENCHMARK_METAL=1 swift test -c release --filter MetalVectorEngineBenchmark`
   - Optimizations A/B: `swift test -c release --filter OptimizationComparisonBenchmark`
   - Vector serialization: `swift test -c release --filter BufferSerializationBenchmark`
   - MiniLM: `WAX_BENCHMARK_MINILM=1 swift test -c release --filter RAGMiniLMBenchmarks`
   - MiniLM batch embedding: `WAX_BENCHMARK_MINILM=1 swift test -c release --filter BatchEmbeddingBenchmark`
   - Tokenizer: `WAX_BENCHMARK_MINILM=1 swift test -c release --filter TokenizerBenchmark`

3) Data extraction
   - For each benchmark test, extract:
     - mean / p50 / p95 / p99 where printed (BenchmarkStats output)
     - docs/sec, texts/sec, ms/text, speedup ratios where printed
     - CPU and memory where collected
   - Output a single markdown table with rows:
     - ingest_text_only, ingest_hybrid, ingest_hybrid_batched
     - text_search, vector_search_cpu, vector_search_metal, unified_hybrid
     - fast_rag_fast, fast_rag_dense_cached
     - memory_orchestrator_ingest, memory_orchestrator_recall
     - cold_open_hybrid, token_count_hot, token_count_cold
     - minilm_embed_hot, minilm_cold_start, minilm_ingest, minilm_recall
     - metal_search_1k/128, metal_lazy_sync_10k/384
     - metadata_lookup_batch_vs_sequential, token_counter_actor_vs_taskhop
     - usearch_buffer_vs_file_serialization

4) Repro notes
   - Record any variance, warmup effects, or flakiness.
   - If any benchmark fails or is skipped, state the env var / dependency needed.

Deliverable:
- `PerfAudit/baseline_results.md` containing raw output excerpts (short) + the extracted metrics table + notes.
