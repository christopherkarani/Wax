Prompt:
You are an LLM judge. Your job is to audit the performance findings for Wax for correctness, avoid speculation, and ensure each claim is supported by benchmark evidence or code references.

Goal:
Return a verdict: which findings are solid, which are weak/unsupported, and what additional evidence is required.

Task BreakDown:
1) For each claim, check:
   - Is it explicitly supported by benchmark output?
   - Is it supported by code structure (file + function + line number(s)) and known platform behavior?
   - Is it actually an algorithmic limit rather than an implementation detail?
2) For any weak claims:
   - Propose the minimal additional benchmark or measurement needed.

Required Context Format Per Claim:
1) Claim:
2) Evidence:
   - Benchmark name + extracted number(s) OR
   - File + function + line number(s)
3) Why the claim matters (impact):
4) Alternative explanations:

Deliverable:
- A markdown report with:
  - Approved claims
  - Rejected claims (with reasons)
  - Required follow-up measurements

---

Claims To Judge (include file + line + evidence)

1) Claim: MiniLM cold start is dominated by runtime model compilation because `.mlmodelc` isn’t present/loaded.
   - Evidence (benchmark): `PerfAudit/Raw/RAGMiniLMBenchmarks_standard.log` → `minilm_cold_start: mean 3.1726 s`
   - Evidence (code): `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:96–133`
     - Fallback path copies `model.mlmodel` + `weight.bin` to temp and calls `MLModel.compileModel(...)` at line 132.
   - Why it matters: first-run UX and first-ingest latency.
   - Alternative explanations: CoreML device specialization/caching, OS cold cache effects.

2) Claim: Current “batch embedding” is not materially batching inference (flat ms/text scaling).
   - Evidence (benchmark): `PerfAudit/Raw/BatchEmbeddingBenchmark.log`
     - Batch sizes 8..64: ~8.66–8.87 ms/text (~113–115 texts/sec)
     - Batch vs sequential (32): only 1.06x
   - Evidence (code): `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:40–64`
     - Builds per-sentence `all_MiniLM_L6_v2Input` and calls `model.predictions(inputs:)`.
   - Why it matters: ingest throughput is bottlenecked by embeddings.
   - Alternative explanations: CoreML internally parallelizes; tokenizer dominates; input shapes differ preventing batch speedups.

3) Claim: Metal vector search still does CPU top‑K selection and this can dominate at large N.
   - Evidence (code): `Sources/WaxVectorSearch/MetalVectorEngine.swift:395–405` (CPU reads distances) + `topK` at `Sources/WaxVectorSearch/MetalVectorEngine.swift:410–452`.
   - Evidence (benchmark proxy): `PerfAudit/Raw/MetalVectorEngineBenchmark.log` shows GPU compute latency only; no topK scaling benchmark.
   - Why it matters: CPU heap selection becomes O(N log k) per query on large N and can erase GPU gains.
   - Alternative explanations: distances are small enough at current N; k is tiny; GPU kernel dominates.

4) Claim: GPU sync strategy copies the entire vectors buffer on any write, which is costly for write-heavy workloads.
   - Evidence (code): `Sources/WaxVectorSearch/MetalVectorEngine.swift:341–346` + `syncVectorsToGPU` at `Sources/WaxVectorSearch/MetalVectorEngine.swift:652–661`.
   - Why it matters: for interleaved add/search, every search can copy full buffer.
   - Alternative explanations: write patterns are batchy; searches happen after large ingest; not a hot path in steady state.

5) Claim: FTS5 deserialize for staged/open path mallocs + memcpy’s the full DB image, increasing cold-open RSS.
   - Evidence (code): `Sources/WaxTextSearch/FTS5Serializer.swift:24–48` (sqlite3_malloc64 + memcpy + sqlite3_deserialize with FREEONCLOSE|RESIZEABLE).
   - Why it matters: larger corpora will incur full-buffer copies on open/stage.
   - Alternative explanations: committed path uses `deserializeReadOnly`; the staged path may be small.

6) Claim: XCTest `measureAsync` introduces a floor around ~0.103s for sub‑10ms operations.
   - Evidence (benchmark): `PerfAudit/Raw/RAGPerformanceBenchmarks_standard.log` shows many metrics at ~0.103s.
   - Evidence (code): `Tests/WaxIntegrationTests/RAGBenchmarkSupport.swift:238–282` uses Task + expectation + wait.
   - Why it matters: prevents meaningful measurement of micro-optimizations.
   - Alternative explanations: operations truly cost ~0.103s; dataset size; hidden waits.
