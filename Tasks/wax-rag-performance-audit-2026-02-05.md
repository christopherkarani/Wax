# Wax RAG Performance Audit (Ground Truth)

Date: 2026-02-05  
Repo: `/Users/chriskarani/CodingProjects/Wax`  
Authoring source: benchmark logs in `/tmp`, code in `Sources/`, tests in `Tests/WaxIntegrationTests/`.

## Purpose
This document is the implementation-grade handoff for coding agents.

It includes:
- Exact benchmark outcomes treated as ground truth.
- Crash/failure signatures with log paths.
- Bottlenecks with exact file + line references.
- Inline code snippets with line numbers.
- Deterministic remediation plan with validation criteria.

## Scope and Constraints
- On-device Wax RAG stack only.
- Apple Silicon/macOS test runner.
- Benchmark outcomes are authoritative; no extrapolation over measured data.
- `MemVid-main` local folder was requested for comparison but is not present in workspace (`find` returned no matches).

---

## 1) Benchmark Ground Truth

## 1.1 RAG Benchmark Matrix (`RAGPerformanceBenchmarks`)
Status source: `/tmp/wax-ragbench-status.tsv`

Passed (`0`):
- `testIngestTextOnlyPerformance`
- `testIngestHybridPerformance`
- `testIngestHybridBatchedPerformance`
- `testIngestTextOnlyPerformance10KDocs`
- `testIngestHybridPerformance10KDocs`
- `testIngestHybridBatchedPerformance10KDocs`
- `testTextSearchPerformance`
- `testVectorSearchPerformance`
- `testFastRAGBuildPerformanceFastMode`
- `testMemoryOrchestratorIngestPerformance`
- `testMemoryOrchestratorRecallPerformance`
- `testTokenCountingPerformance`
- `testTokenCountingColdStartPerformance`
- `testUnifiedSearchHybridWarmLatencySamples`
- `testUnifiedSearchHybridWarmLatencySamplesCPUOnly`
- `testFramePreviewsWarmLatencySamples`
- `testWaxOpenCloseColdLatencySamples`
- `testIncrementalStageAndCommitLatencySamples`
- `testUnifiedSearchHybridPerformance10KDocsCPU`

Failed/Crashing (`1`):
- `testUnifiedSearchHybridPerformance` (signal 11)
- `testUnifiedSearchHybridPerformanceWithMetrics` (signal 11)
- `testFastRAGBuildPerformanceDenseCached` (signal 11)
- `testColdOpenHybridSearchPerformance` (signal 11)
- `testUnifiedSearchHybridPerformance10KDocs` (signal 11)

## 1.2 Key Measured Results
Evidence files:
- `/tmp/wax-rag-test*.log`
- `/tmp/wax-metal-bench.log`
- `/tmp/wax-buffer-bench.log`
- `/tmp/wax-opt-bench.log`
- `/tmp/wax-tokenizer-bench.log`
- `/tmp/wax-batch-embed-bench.log`
- `/tmp/wax-minilm-*.log`

Core RAG:
- Ingest text-only 10K: **15.180s avg** (`/tmp/wax-rag-testIngestTextOnlyPerformance10KDocs.log`)
- Ingest hybrid 10K: **31.569s avg** (`/tmp/wax-rag-testIngestHybridPerformance10KDocs.log`)
- Ingest hybrid batched 10K: **7.480s avg** (`/tmp/wax-rag-testIngestHybridBatchedPerformance10KDocs.log`)
- Unified hybrid search 10K CPU-only: **0.103s avg** (`/tmp/wax-rag-testUnifiedSearchHybridPerformance10KDocsCPU.log`)
- MemoryOrchestrator ingest: **0.214s avg** (`/tmp/wax-rag-testMemoryOrchestratorIngestPerformance.log`)
- MemoryOrchestrator recall: **0.102s avg** (`/tmp/wax-rag-testMemoryOrchestratorRecallPerformance.log`)

Warm sampled latency:
- Hybrid warm previews: **1.6ms mean**
- Hybrid warm no previews: **1.6ms mean**
- Hybrid warm CPU-only: **1.4ms mean**
- Frame previews topK 512b: **0.1ms mean**
- Open/close cold: **1.9ms mean**
- Incremental stage: **18.5ms mean**
- Incremental commit: **12.4ms mean**

Metal vector benchmarks:
- Cold search (10K x 384): **6.10ms**
- Warm search avg (10K x 384): **1.23ms**
- Warm speedup: **5.0x**
- 1K x 128 avg search: **1.77ms**, **0.0018ms/vector**

Serialization benchmark:
- Save buffer vs file: **16.4x faster**
- Load buffer vs file: **2.6x faster**
- Total speedup: **7.6x**

Optimization micro-benchmark:
- Direct actor calls vs task hop: **1.1x faster**, **6.6%** improvement
- Batched metadata lookup: **1.3x faster**, **23.5%** improvement

MiniLM:
- `minilm_embed`: **20.9ms mean**
- `minilm_embed_batch32`: **623.7ms mean total** (~19.5ms/text)
- `minilm_cold_start`: **30.07s mean**, **p95 81.13s**, **p99 88.34s**
- `testMiniLMIngestPerformance`: **0.206s avg**
- `testMiniLMRecallPerformance`: **fails** with normalization error
- `testMiniLMOpenAndFirstRecallOnExistingStoreSamples`: **signal 11**

## 1.3 Hard Failure Evidence (verbatim locations)
- `/tmp/wax-rag-testUnifiedSearchHybridPerformance.log:4` -> `error: Exited with unexpected signal code 11`
- `/tmp/wax-rag-testUnifiedSearchHybridPerformanceWithMetrics.log:4` -> signal 11
- `/tmp/wax-rag-testFastRAGBuildPerformanceDenseCached.log:4` -> signal 11
- `/tmp/wax-rag-testColdOpenHybridSearchPerformance.log:4` -> signal 11
- `/tmp/wax-rag-testUnifiedSearchHybridPerformance10KDocs.log:4` -> signal 11
- `/tmp/wax-minilm-open-first.log:4` -> signal 11
- `/tmp/wax-minilm-recall.log:8` -> `encodingError(reason: "Metal vector search requires normalized query embeddings")`

---

## 2) Performance Score

Overall score: **57 / 100**

Scoring basis:
- Strong warm-path latency and I/O efficiency.
- Severe penalties for benchmark crashes and MiniLM cold-start tail.
- See root causes below for concrete remediation.

---

## 3) Bottleneck Inventory (Fix-Ready)

Each item includes: symptom, benchmark evidence, code evidence, root cause class, and deterministic fix steps.

### P0-01 — Hybrid search / dense cached / cold-open stability crash (signal 11)

Category: Stability blocker  
Impact: Blocks trustworthy perf evaluation and production confidence.

Benchmark evidence:
- `/tmp/wax-rag-testUnifiedSearchHybridPerformance.log:4`
- `/tmp/wax-rag-testFastRAGBuildPerformanceDenseCached.log:4`
- `/tmp/wax-rag-testColdOpenHybridSearchPerformance.log:4`
- `/tmp/wax-rag-testUnifiedSearchHybridPerformance10KDocs.log:4`
- `/tmp/wax-minilm-open-first.log:4`

Primary code surfaces involved by failing tests:
- `/Users/chriskarani/CodingProjects/Wax/Sources/Wax/UnifiedSearch/UnifiedSearch.swift`
- `/Users/chriskarani/CodingProjects/Wax/Sources/Wax/RAG/FastRAGContextBuilder.swift`
- `/Users/chriskarani/CodingProjects/Wax/Sources/Wax/UnifiedSearch/UnifiedSearchEngineCache.swift`
- `/Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/MetalVectorEngine.swift`

Root cause class: unresolved crash path (likely implementation-level bug, not algorithmic).

Agent fix tasks:
1. Add crash reproducer tests for each failing benchmark path under `Tests/WaxIntegrationTests/`.
2. Add staged instrumentation timers and state checkpoints in:
   - `UnifiedSearch.search(...)`
   - `FastRAGContextBuilder.build(...)`
   - `UnifiedSearchEngineCache.vectorEngine(...)`
3. Run each failing benchmark with instrumentation enabled; isolate last checkpoint before signal 11.
4. Patch crash source and keep reproducer test.

Acceptance:
- All failing benchmark methods complete without signal 11.

---

### P0-02 — MiniLM recall fails due embedding normalization guard

Category: Correctness + performance gate  
Impact: MiniLM recall perf cannot be measured in Metal path.

Benchmark evidence:
- `/tmp/wax-minilm-recall.log:8`

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/UnifiedSearch/UnifiedSearch.swift:103-108
103 async let vectorResultsAsync: [(frameId: UInt64, score: Float)] = {
104     guard includeVector, let vectorEngine, let embedding = request.embedding, !embedding.isEmpty else { return [] }
105     if vectorEngine is MetalVectorEngine, !VectorMath.isNormalizedL2(embedding) {
106         throw WaxError.encodingError(reason: "Metal vector search requires normalized query embeddings")
107     }
108     return try await vectorEngine.search(vector: embedding, topK: candidateLimit)
```

Root cause class: implementation mismatch between query embedding pipeline and Metal guard (supported by log).

Agent fix tasks:
1. Normalize query embedding in-place before Metal search if not normalized.
2. Keep strict validation in debug mode but avoid benchmark-breaking throw in release perf mode.
3. Add test: `testMetalQueryEmbeddingNormalizationEnforced`.

Acceptance:
- `testMiniLMRecallPerformance` passes.
- No normalization-related errors in logs.

---

### P0-03 — Batched ingest still writes embeddings per frame (N actor hops + N WAL appends)

Category: Write-path throughput bottleneck  
Impact: Prevents max ingest throughput at scale.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/WaxSession.swift:307-313
307 let frameIds = try await wax.putBatch(contents, options: mergedOptions, compression: compression)
308 guard frameIds.count == embeddings.count else { ... }
311 for (index, frameId) in frameIds.enumerated() {
312     try await wax.putEmbedding(frameId: frameId, vector: embeddings[index])
313 }
```

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxCore/Wax.swift:766-847 (already available batch API)
766 public func putEmbeddingBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
...
838 let sequences = try await io.run {
839     try wal.appendBatch(payloads: walPayloadsArray)
840 }
```

Root cause class: implementation inefficiency (judge verdict: partially supported severity, supported structure).

Agent fix tasks:
1. Replace looped `putEmbedding` in both `WaxSession.putBatch` overloads with `putEmbeddingBatch`.
2. Preserve dimension checks and identity metadata semantics.
3. Add benchmark: `testPutBatchWithEmbeddingsVsPutEmbeddingBatch`.

Acceptance:
- `testIngestHybridPerformance10KDocs` improves significantly.
- WAL append count per ingest batch drops from O(n) calls to O(1) batch call.

---

### P0-04 — Per-item cache actor hops in embedding prep despite batch APIs existing

Category: Concurrency overhead  
Impact: needless serialization in high-throughput ingest.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/Orchestrator/MemoryOrchestrator.swift:243-257
243 if let cache {
244     for (index, chunk) in chunks.enumerated() {
...
251         if let cached = await cache.get(key) {
252             results[index] = cached
253         } else {
254             missingIndices.append(index)
255             missingTexts.append(chunk)
256         }
257     }
}
```

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/Orchestrator/MemoryOrchestrator.swift:329-338
329 if let cache {
...
337     await cache.set(key, value: vec)
338 }
```

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/Embeddings/EmbeddingMemoizer.swift:42-61, 88-95
42 func getBatch(_ keys: [UInt64]) -> [UInt64: [Float]] { ... }
88 func setBatch(_ items: [(key: UInt64, value: [Float])]) { ... }
```

Root cause class: implementation inefficiency.

Agent fix tasks:
1. Compute all keys once.
2. Use `getBatch` for lookups.
3. Use `setBatch` for misses.
4. Add per-batch cache hit/miss counters to logs.

Acceptance:
- Ingest benchmark improves (target: >=10-20% for cache-active workloads).

---

### P1-05 — RRF fusion does full candidate accumulation + full sort (no early topK prune)

Category: Algorithmic bottleneck  
Impact: O(U log U) at hybrid merge.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/UnifiedSearch/HybridSearch.swift:29-49
29 let kConstant = max(0, k)
30 var scores: [UInt64: Float] = [:]
31 var bestRank: [UInt64: Int] = [:]
...
42 return scores.map { (frameId: $0.key, score: $0.value) }
43     .sorted { a, b in
44         if a.score != b.score { return a.score > b.score }
45         let ra = bestRank[a.frameId] ?? Int.max
46         let rb = bestRank[b.frameId] ?? Int.max
47         if ra != rb { return ra < rb }
48         return a.frameId < b.frameId
49     }
```

Root cause class: algorithmic.

Agent fix tasks:
1. Introduce bounded candidate windows from each lane.
2. Replace global full sort with topK heap selection.
3. Preserve deterministic tie-break.

Acceptance:
- `testUnifiedSearchHybridPerformance10KDocsCPU` improves while preserving deterministic ordering.

---

### P1-06 — Metal vector add/update path uses repeated linear lookup (`firstIndex`) in loops

Category: Algorithmic + data structure bottleneck  
Impact: O(N^2) behavior in batch ingest/update.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/MetalVectorEngine.swift:334-353
334 if let existingIndex = frameIds.firstIndex(of: frameId) {
...
351     frameIds.append(frameId)
352     vectorCount += 1
353 }
```

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/MetalVectorEngine.swift:384-397
384 for (frameId, vector) in zip(frameIds, vectors) {
385     if let existingIndex = self.frameIds.firstIndex(of: frameId) {
...
395         self.frameIds.append(frameId)
396         vectorCount += 1
397     }
}
```

Root cause class: algorithmic data structure mismatch.

Agent fix tasks:
1. Add `frameIdToIndex` map.
2. Update add/update/remove to O(1) expected lookup.
3. Switch delete to swap-remove with map fixup.

Acceptance:
- New benchmark `testMetalAddBatchScaling` shows sub-quadratic scaling.

---

### P1-07 — Metal search allocates reduction buffers per query

Category: GPU memory lifecycle overhead  
Impact: avoidable allocation churn and jitter.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/MetalVectorEngine.swift:517-551
517 let stage1Length = stage1Count * MemoryLayout<TopKEntry>.stride
518 guard let stage1Buffer = device.makeBuffer(length: stage1Length, options: .storageModeShared) else { ... }
...
547 let nextLength = nextCount * MemoryLayout<TopKEntry>.stride
548 guard let nextBuffer = device.makeBuffer(length: nextLength, options: .storageModeShared) else { ... }
```

Root cause class: implementation memory lifecycle.

Agent fix tasks:
1. Add persistent/reusable reduction buffer pool keyed by `(vectorCountBucket, topK)`.
2. Reuse across queries.
3. Add memory high-watermark tracking.

Acceptance:
- lower warm-path p95/p99 latency variance in Metal benchmark.

---

### P1-08 — Vector serializer decode path materializes full arrays (copy heavy)

Category: Memory + I/O overhead  
Impact: high peak memory and unnecessary copies on index load.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/VectorSerializer.swift:146-151
146 let vectors = Array(vectorsData.withUnsafeBytes {
147     Array($0.bindMemory(to: Float.self))
148 })
149 let frameIds = Array(data[offset..<offset + Int(frameIdLength)].withUnsafeBytes {
150     Array($0.bindMemory(to: UInt64.self))
151 })
```

Related downstream cost:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/USearchVectorEngine.swift:274-286
274 try await io.run {
275     var scratch = [Float](repeating: 0, count: dims)
...
284     try index.add(key: frameIdArray[i], vector: scratch)
285 }
```

Root cause class: implementation (data movement).

Agent fix tasks:
1. Introduce decode-to-buffer path.
2. Avoid materializing full `[Float]` and `[UInt64]` when not required.
3. Add batched add API path for USearch conversion.

Acceptance:
- Index load benchmark improves; reduced peak RSS.

---

### P1-09 — Tokenizer vocab is loaded from disk every tokenizer init

Category: Cold-start bottleneck  
Impact: extreme MiniLM cold-start tails.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearchMiniLM/CoreML/BertTokenizer.swift:49-55
49 public init() throws {
50     let sharedVocab = try BertTokenizer.loadVocab()
51     self.vocab = sharedVocab.vocab
52     self.ids_to_tokens = sharedVocab.idsToTokens
53     self.basicTokenizer = Self.sharedBasicTokenizer
54     self.wordpieceTokenizer = WordpieceTokenizer(vocab: sharedVocab.vocab)
55 }
```

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearchMiniLM/CoreML/BertTokenizer.swift:372-387
372 static func loadVocab() throws -> VocabData {
373     guard let url = Bundle.module.url(forResource: "bert_tokenizer_vocab", withExtension: "txt") else { ... }
376     let vocabTxt = try String(contentsOf: url, encoding: .utf8)
377     let tokens = vocabTxt.split(separator: "\n").map { String($0) }
...
387     return VocabData(vocab: vocab, idsToTokens: idsToTokens)
}
```

Root cause class: implementation initialization strategy.

Agent fix tasks:
1. Add static thread-safe vocab cache (once-only load).
2. Reuse cached `VocabData` across tokenizer instances.
3. Add benchmark for tokenizer init latency.

Acceptance:
- `minilm_cold_start` p95 drops materially.

---

### P1-10 — Batch tokenizer path zeroes full MLMultiArray buffers every call

Category: Memory bandwidth overhead  
Impact: repeated full-buffer writes.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearchMiniLM/CoreML/BertTokenizer.swift:234-237
234 let idsPtr = UnsafeMutablePointer<Int32>(OpaquePointer(buffers.inputIds.dataPointer))
235 let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(buffers.attentionMask.dataPointer))
236 idsPtr.initialize(repeating: 0, count: buffers.inputIds.count)
237 maskPtr.initialize(repeating: 0, count: buffers.attentionMask.count)
```

Root cause class: implementation memory policy.

Agent fix tasks:
1. Zero only active slice or maintain rolling clear strategy.
2. Validate no stale-token leakage via tests.

Acceptance:
- batch tokenization throughput improvement on `TokenizerBenchmark` and MiniLM batch runs.

---

### P1-11 — MiniLM batching currently gives only marginal gain vs sequential in orchestrated benchmark

Category: CoreML pipeline inefficiency  
Impact: weak step-up from batching in current test path.

Benchmark evidence:
- `/tmp/wax-batch-embed-bench.log:35-38`
  - Sequential: 306.0ms total
  - Batch: 293.2ms total
  - Speedup: 1.04x

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift:104-118
104 public func embed(batch texts: [String]) async throws -> [[Float]] {
...
109     for size in plannedBatches {
112         let chunk = Array(texts[batchStart..<batchEnd])
113         let embeddings = try await embedBatchCoreML(texts: chunk)
...
118     }
}
```

Root cause class: likely implementation path overhead (chunk slicing, tokenizer prep costs dominating).

Agent fix tasks:
1. Remove avoidable array slicing copies.
2. Profile tokenization vs CoreML inference split.
3. tune sequence buckets and batch strategy by real shape distribution.

Acceptance:
- measurable speedup >1.25x in batch-vs-seq benchmark.

---

### P2-12 — Prewarm strategy duplicates work

Category: Startup overhead  
Impact: extra cold-start cost.

Code evidence:

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/Orchestrator/MemoryOrchestrator+Prewarm.swift:13-17
13 public static func miniLM(sampleText: String = "hello") async throws {
14     let embedder = try MiniLMEmbedder()
15     _ = try await embedder.embed(sampleText)
16     try await embedder.prewarm()
17 }
```

```swift
// /Users/chriskarani/CodingProjects/Wax/Sources/Wax/Adapters/MemoryOrchestrator+MiniLM.swift:10-12
10 let embedder = try MiniLMEmbedder()
11 try await embedder.prewarm()
12 return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
```

Root cause class: implementation startup policy.

Agent fix tasks:
1. Centralize one prewarm policy path.
2. Avoid duplicate warmup calls per app lifecycle.

Acceptance:
- lower cold-open + first-recall latency once crash fixed.

---

## 4) Algorithmic Limits vs Implementation Debt

Algorithmic limits (must redesign):
- RRF full-set sort (`HybridSearch.swift:42-49`).
- Full-scan vector distance path in Metal search (`MetalVectorEngine.swift:446+`).
- WordPiece substring-heavy tokenization loops (`BertTokenizer.swift:457+`).

Implementation debt (fix in-place):
- Per-frame embedding writes in `WaxSession.putBatch`.
- Per-item cache actor hops in `MemoryOrchestrator`.
- `firstIndex` lookup patterns in Metal add/update.
- Per-query GPU buffer allocations.
- decode materialization copies in `VectorSerializer`.
- repeated vocab load and full buffer zeroing in tokenizer.

---

## 5) Deterministic Fix Plan for Coding Agents

Ordered execution (do not reorder):

Execution gates (must pass before advancing):
- Gate A (before lanes 2-5): zero signal-11 failures in:
  - `testUnifiedSearchHybridPerformance`
  - `testUnifiedSearchHybridPerformanceWithMetrics`
  - `testFastRAGBuildPerformanceDenseCached`
  - `testColdOpenHybridSearchPerformance`
  - `testUnifiedSearchHybridPerformance10KDocs`
  - `testMiniLMOpenAndFirstRecallOnExistingStoreSamples`
- Gate B (before lanes 2-5): `testMiniLMRecallPerformance` passes with no normalization error.
- Gate C (before lane 4): lane 2 and lane 3 checkpoint benchmarks pass and show non-regression vs prior lane.
- Gate D (before lane 5): lane 4 checkpoint benchmarks pass and include vector-engine correctness parity checks.
- Parallelization rule after Gate A/B: lanes 2 and 3 may run in parallel if they do not edit the same files; lane 4 starts only after both finish; lane 5 starts only after lane 4.

1. Stability lane (P0)
- Fix normalization failure and signal-11 repro harness.
- Target files:
  - `/Users/chriskarani/CodingProjects/Wax/Sources/Wax/UnifiedSearch/UnifiedSearch.swift`
  - `/Users/chriskarani/CodingProjects/Wax/Sources/Wax/RAG/FastRAGContextBuilder.swift`
  - `/Users/chriskarani/CodingProjects/Wax/Sources/Wax/UnifiedSearch/UnifiedSearchEngineCache.swift`
  - `/Users/chriskarani/CodingProjects/Wax/Sources/WaxVectorSearch/MetalVectorEngine.swift`

2. Ingest write-path lane
- Replace per-frame embedding writes with `putEmbeddingBatch` in `WaxSession`.
- Batch cache get/set in `MemoryOrchestrator`.

3. Hybrid algorithm lane
- Implement bounded/topK fusion without full global sort.

4. Vector engine lane
- Add frameId index map.
- Pool reduction buffers.
- reduce load-path copy churn.

5. CoreML/tokenizer lane
- static vocab cache.
- reduced buffer zeroing.
- remove avoidable slicing and duplicate prewarm paths.

### Acceptance benchmark checkpoints
After each lane run:
- `swift test --filter RAGPerformanceBenchmarks`
- `WAX_BENCHMARK_METAL=1 swift test --filter MetalVectorEngineBenchmark`
- `WAX_BENCHMARK_MINILM=1 swift test --filter RAGMiniLMBenchmarks`
- `WAX_BENCHMARK_MINILM=1 swift test --filter BatchEmbeddingBenchmark`
- `swift test --filter BufferSerializationBenchmark`

---

## 6) Missing Benchmark Coverage (add to suite)

Required additions:
1. Concurrent recall scaling (1/2/4/8/16 parallel queries).
2. Memory high-watermark + allocation count per benchmark stage.
3. Update/delete-heavy vector benchmark (not just append/search).
4. Long-run stability soak benchmark (10k+ repeated queries).
5. On-device power/energy profile benchmark under thermal constraints.
6. Dimensional scaling benchmark (384/768/1536).

Suggested locations:
- `/Users/chriskarani/CodingProjects/Wax/Tests/WaxIntegrationTests/RAGBenchmarks.swift`
- `/Users/chriskarani/CodingProjects/Wax/Tests/WaxIntegrationTests/MetalVectorEngineBenchmark.swift`
- New files under `/Users/chriskarani/CodingProjects/Wax/Tests/WaxIntegrationTests/`:
  - `RAGConcurrencyBenchmarks.swift`
  - `MemoryAllocationBenchmarks.swift`
  - `VectorUpdateDeleteBenchmarks.swift`
  - `StabilitySoakBenchmarks.swift`

---

## 7) External Context for Architectural Choices

Used as design context (not treated as Wax benchmark ground truth):
- Apple Metal/Metal 4 guidance.
- CoreML lifecycle and warmup best practices.
- ANN/vector indexing patterns from USearch/FAISS/Qdrant docs.
- MemVid public references (no local `MemVid-main` folder available in workspace).

---

## 8) LLM-as-Judge Verification Summary

Independent validation outcomes for key claims:
- Supported:
  - normalization-guard benchmark failure (`UnifiedSearch.swift:106` + log).
  - O(N^2) `firstIndex` pattern in Metal add/update path.
  - RRF full accumulation + full sort.
- Partially supported (structure proven, magnitude needs benchmark deltas):
  - “major bottleneck” severity labels for some write/cache paths.

This means the remediation list is structurally correct; for severity ranking, rerun benchmarks after each fix lane.

---

## 9) Extreme-Performance Optimization Areas (Final List)

To reach extreme performance, optimize all of:
- Crash/stability path in hybrid/dense-cached/cold-open benchmarks.
- Query embedding normalization invariants for Metal.
- Ingest embedding write path batching (`putEmbeddingBatch` usage).
- Cache actor-hop collapse in embedding prep.
- RRF/topK hybrid fusion algorithm.
- Metal engine index data structures and query memory lifecycle.
- Serializer/decode copy elimination.
- Tokenizer cold-start path (vocab load/cache) and batch buffer policies.
- MiniLM batching pipeline effectiveness.
- Benchmark suite breadth for concurrency/memory/power/tail latency.
