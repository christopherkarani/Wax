Prompt:
You are an LLM judge. Your job is to audit the performance findings for Wax for correctness, avoiding speculation, and ensuring each claim is supported by (a) benchmark evidence or (b) direct code references.

Goal:
Return a verdict: which findings are solid, which are weak/unsupported, and what additional evidence is required.

Task BreakDown:
1) For each claim, check:
   - Is it explicitly supported by benchmark output?
   - Is it supported by code structure (file + function) and known platform behavior?
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
   - Evidence (code): `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:96–134`
     - Fallback path copies `model.mlmodel` + `weight.bin` to temp and calls `MLModel.compileModel(...)` at line 132.
   - Why it matters: first-run UX and first-ingest latency.
   - Alternative explanations to consider: CoreML device specialization/caching, OS cold cache effects.

2) Claim: Current “batch embedding” is not materially batching inference (flat ms/text scaling).
   - Evidence (benchmark): `PerfAudit/Raw/BatchEmbeddingBenchmark.log`
     - Batch sizes 8..64: ~8.66–8.87 ms/text (~113–115 texts/sec)
     - Batch vs sequential (32): only 1.06x
   - Evidence (code): `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:40–66`
     - Builds per-sentence `all_MiniLM_L6_v2Input` and calls `model.predictions(inputs:)`.
   - Why it matters: ingest throughput is bottlenecked by embeddings.
   - Alternative explanations: CoreML internally parallelizes; tokenizer dominates; input shapes differ preventing batching.

3) Claim: MetalVectorEngine add/addBatch is asymptotically O(N^2) due to linear `firstIndex(of:)` lookups.
   - Evidence (code): `Sources/WaxVectorSearch/MetalVectorEngine.swift:189–249`
     - `frameIds.firstIndex(of:)` at lines 193 and 237 inside per-element loops.
   - Evidence (benchmark proxy): `PerfAudit/Raw/RAGPerformanceBenchmarks_10k.log`
     - Hybrid ingest 10k: 1.637s; batched: 0.724s (shows batching helps but doesn’t prove asymptotics).
   - Why it matters: >50k vectors will blow up ingest latency.
   - Alternative explanations: reserve/copy behavior, GPU sync, IO dominates.

4) Claim: MetalVectorEngine remove is O(N * dims) and causes large array shifting.
   - Evidence (code): `Sources/WaxVectorSearch/MetalVectorEngine.swift:275–288`
     - `vectors.remove(at:)` repeated `dimensions` times (lines 280–283).
   - Why it matters: deletes become very expensive at scale; impacts compaction/maintenance.
   - Alternative explanations: low delete frequency; delete done in batches elsewhere.

5) Claim: FTS index open duplicates memory because FTS5Serializer malloc+memcpy’s the entire DB image.
   - Evidence (code): `Sources/WaxTextSearch/FTS5Serializer.swift:24–53`
     - `sqlite3_malloc64` + `memcpy` then `sqlite3_deserialize` with FREEONCLOSE|RESIZEABLE (lines 31–52).
   - Why it matters: cold open RSS + time degrade with corpus size; hurts on-device budgets.
   - Alternative explanations: FTS DB remains small; serialize/deserialise only at commit boundaries.

6) Claim: Many XCTest `measureAsync` results are harness-limited (~0.103s floor) and not reliable for <10ms operations.
   - Evidence (benchmark): `PerfAudit/Raw/RAGPerformanceBenchmarks_standard.log` shows many measures near 0.103s.
   - Evidence (code): `Tests/WaxIntegrationTests/RAGBenchmarkSupport.swift:239–288`
     - Each iteration spawns a Task + waits on XCTest expectation (known overhead).
   - Why it matters: prevents micro-optimization work from being measurable.
   - Alternative explanations: operations truly take ~0.103s; dataset sizes; hidden sleeps.
