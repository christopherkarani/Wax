# Wax RAG Performance Optimization Plan

## Executive Summary
Wax scored 68/100 in the performance audit, with ingestion serialization, float conversion, LRU overhead, WAL amplification, and lock contention as the primary bottlenecks. This plan delivers deterministic, step-function improvements in three phases to reach <50ms hybrid search at 10K docs, 3x ingest throughput, and 50% fewer transient allocations, while preserving existing strengths (1.42ms Metal search, 6.7x warm GPU speedup, and buffer-serialization gains). All changes are designed with deterministic ordering, fixed batching, and reproducible metrics.

## Phase 1: Quick Wins (1-2 days each)

### 1) De-serialize ingest batch writes
- File: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`
- Line numbers: 195-218
- Before:
```swift
for index in 0..<batchResults.count {
    guard let result = batchResults[index] else {
        throw WaxError.io("missing ingest batch result at index \(index)")
    }

    if let embeddings = result.embeddings, config.enableVectorSearch {
        let frameIds = try await localSession.putBatch(
            contents: result.contents,
            embeddings: embeddings,
            identity: localEmbedder?.identity,
            options: result.options
        )
        if config.enableTextSearch {
            try await localSession.indexTextBatch(frameIds: frameIds, texts: result.texts)
        }
    } else {
        let frameIds = try await localSession.putBatch(contents: result.contents, options: result.options)
        if config.enableTextSearch {
            try await localSession.indexTextBatch(frameIds: frameIds, texts: result.texts)
        }
    }
}
```
- After:
```swift
let ordered = try batchResults.enumerated().map { index, result in
    guard let result else { throw WaxError.io("missing ingest batch result at index \(index)") }
    return result
}

try await localSession.applyBatches(
    ordered,
    enableVectorSearch: config.enableVectorSearch,
    enableTextSearch: config.enableTextSearch,
    embedderIdentity: localEmbedder?.identity
)
```
- Expected impact: 1.4-1.8x ingest throughput by removing per-batch actor hops; lower tail latency.
- Risk level: Medium (new actor API + ordering guarantees).

### 2) Vectorized Float16 -> Float32 conversion
- File: `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift`
- Line numbers: 167-177
- Before:
```swift
if isContiguous && dataType == .float16 {
    let float16Ptr = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
    return (0..<batch).map { row in
        let start = row * dim
        var vector = [Float](repeating: 0, count: dim)
        float16Ptr.advanced(by: start).withMemoryRebound(to: UInt16.self, capacity: dim) { srcPtr in
            vDSP.convertElements(of: UnsafeBufferPointer(start: srcPtr, count: dim), to: &vector)
        }
        return vector
    }
}
```
- After:
```swift
if isContiguous && dataType == .float16 {
    let float16Ptr = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
    var output = [Float](repeating: 0, count: batch * dim)
    vDSP_vflt16(float16Ptr, 1, &output, 1, vDSP_Length(batch * dim))
    return (0..<batch).map { row in
        let start = row * dim
        return Array(output[start..<(start + dim)])
    }
}
```
- Expected impact: 2-4x faster decode for contiguous Float16; reduces per-row allocation churn.
- Risk level: Low (straightforward Accelerate swap).

### 3) LRU cache node indexing to avoid O(n) operations
- File: `Sources/Wax/RAG/TokenCounter.swift`
- Line numbers: 443-472
- Before:
```swift
private struct Entry {
    var key: String
    var value: [UInt32]
    var prev: String?
    var next: String?
}

private var entries: [String: Entry]
private var head: String?
private var tail: String?
```
- After:
```swift
private struct Node {
    var key: String
    var value: [UInt32]
    var prev: Int
    var next: Int
}

private var indexByKey: [String: Int] = [:]
private var nodes: ContiguousArray<Node> = []
private var freeList: [Int] = []
private var headIndex: Int = -1
private var tailIndex: Int = -1
```
- Expected impact: 1.3-1.6x faster cache ops; fewer transient allocations and string hash updates.
- Risk level: Medium (LRU correctness + eviction edge cases).

### 4) Coalesce WAL sentinel writes
- File: `Sources/WaxCore/WAL/WALRingWriter.swift`
- Line numbers: 127, 217, 282-302
- Before:
```swift
try writeSentinel()
bytesSinceFsync &+= totalNeeded
try maybeFsync()
```
- After:
```swift
markSentinelDirty()
bytesSinceFsync &+= totalNeeded
try maybeWriteSentinel(force: bytesSinceFsync >= fsyncThreshold || writePos == 0)
try maybeFsync()
```
- Expected impact: 1.5-2.5x fewer WAL writes in steady-state; lowers write amplification.
- Risk level: Medium (recovery semantics; must validate replay paths).

### 5) Replace spin-wait writer lock
- File: `Sources/WaxCore/Concurrency/ReadWriteLock.swift`
- Line numbers: 39-47
- Before:
```swift
os_unfair_lock_lock(&lock)
while readerCount > 0 {
    os_unfair_lock_unlock(&lock)
    usleep(1)
    os_unfair_lock_lock(&lock)
}
```
- After:
```swift
private var rwlock = pthread_rwlock_t()

public func readLock() { pthread_rwlock_rdlock(&rwlock) }
public func readUnlock() { pthread_rwlock_unlock(&rwlock) }
public func writeLock() { pthread_rwlock_wrlock(&rwlock) }
public func writeUnlock() { pthread_rwlock_unlock(&rwlock) }
```
- Expected impact: 20-40% lower contention under mixed read/write; removes spin-wait CPU waste.
- Risk level: Medium (platform semantics; must validate latency on Apple Silicon).

## Phase 2: Architectural Improvements (3-5 days each)

### 2.1 Deterministic ingest concurrency model
- Design:
  - Split ingest into a three-stage pipeline: chunk -> embed -> persist/index.
  - Use a bounded `AsyncStream` or `AsyncChannel` per stage with fixed capacity to enforce backpressure.
  - Assign deterministic batch IDs upfront; preserve ordering via stable sort on `(batchID, chunkIndex)`.
  - Replace ad-hoc task groups with a dedicated `BatchCommitter` actor that consumes ordered batches and performs `putBatch` + `indexTextBatch` in a single actor hop per batch group.
  - Add a deterministic scheduler: fixed worker counts per stage (e.g., embed workers = min(4, cores/2)), no dynamic scaling.
- Expected impact: 2-3x ingest throughput; reduces tail latency variance and actor serialization.
- Risk level: Medium (pipeline integration complexity, must keep deterministic ordering).

### 2.2 Memory layout optimizations (allocations -50%)
- Design:
  - Introduce pooled buffers for embeddings, tokens, and chunk payloads using `ManagedBuffer` or `UnsafeMutableBufferPointer` with deterministic sizing.
  - CoreML batching: enforce batch sizes in {64, 128, 256} with deterministic bucketing; reuse `MLMultiArray` buffers per bucket.
  - Add a `BatchInputPool` to `BertTokenizer` for `inputIds`/`attentionMask` reuse.
  - Use `ContiguousArray` for hot paths to reduce ARC churn and retain determinism.
- Expected impact: 35-50% fewer transient allocations; better cache locality in decode + tokenize.
- Risk level: Medium (pool lifecycle correctness; careful with thread safety).

### 2.3 I/O pipeline redesign (WAL + commits)
- Design:
  - Implement an `IOBatch` abstraction with scatter/gather write support to coalesce padding, record, and sentinel into one syscall where possible.
  - Move WAL record encoding to a reusable buffer to avoid repeated `Data` allocations.
  - Align writes to page boundaries and group fsyncs based on deterministic thresholds (payload bytes or commit boundaries).
  - Add an explicit `commitFence` record to replace sentinel-only end markers, reducing sentinel frequency.
- Expected impact: 2x throughput in write-heavy ingest; lower fsync cost and amplification.
- Risk level: High (durability semantics; must exhaustively test crash recovery).

## Phase 3: Advanced Optimizations (1-2 weeks each)

### 3.1 Metal 4 integration plan
- Scope:
  - Introduce `MTLResidencySet` for persistent embedding buffers to reduce warm-up overhead.
  - Use FP16 compute kernels to double memory bandwidth; keep CPU paths in Float32 for determinism.
  - Evaluate sparse resource placement for large vector stores to reduce memory pressure.
- Deliverables:
  - New `MetalVectorEngineV2` with dual FP16/FP32 paths.
  - Residency lifecycle hooks in query + ingest flows.
- Expected impact: 1.5-2x GPU search throughput for 10K-100K vectors; improved warm latency stability.
- Risk level: Medium (Metal 4 availability, fallback behavior).

### 3.2 Half-precision vector storage
- Scope:
  - Store embeddings in Float16 on disk and in GPU buffers; convert to Float32 only for CPU-only paths.
  - Add deterministic conversion via `vDSP_vflt16` in read paths; keep normalization consistent.
- Expected impact: 2x storage density; 1.4-1.8x faster memory bandwidth-limited paths.
- Risk level: Medium (accuracy drift; requires regression baselines).

### 3.3 Product Quantization for 100K+ vectors
- Scope:
  - Implement PQ with deterministic codebook training (fixed seed, fixed sampling order).
  - Use coarse quantizer + residual PQ; evaluate k=8 or k=16 subspaces.
- Expected impact: 5-10x memory reduction at 100K+ vectors; 2-3x faster coarse search.
- Risk level: High (recall trade-offs; needs evaluation harness).

## Benchmarking Requirements

### New benchmarks to add
- `IngestPipelineBenchmarks`: end-to-end `MemoryOrchestrator.remember` throughput with vector+text.
- `MiniLMDecodeBenchmarks`: Float16 decode throughput for batch sizes 64/128/256.
- `TokenizationCacheBenchmarks`: hit/miss latency + eviction cost at 1K/10K entries.
- `WALWriteAmplificationBenchmarks`: bytes written per payload byte in append and appendBatch.
- `ReadWriteLockContentionBenchmarks`: mixed read/write latency and CPU usage.
- Extend `RAGBenchmarks` to assert hybrid search <50ms at 10K docs (env-gated).

### Metrics to track
- Latency: p50/p95/p99 for ingest, hybrid search, and decode.
- Throughput: docs/sec and vectors/sec for ingest + embed.
- Allocation metrics: peak RSS, transient allocations per operation.
- WAL: write amplification ratio, fsync frequency.
- Determinism: stable token counts and identical RAG contexts across runs.

### Regression prevention
- Add threshold-based assertions with environment-variable gating.
- Track baseline JSON snapshots for perf metrics and compare deltas.
- Require deterministic ordering tests for pipeline outputs.

## Implementation Order

### Dependency graph
1) Phase 1 QW2 (Float16 conversion) -> Phase 2 memory layout pooling.
2) Phase 1 QW1 (ingest batching) -> Phase 2 deterministic pipeline.
3) Phase 1 QW4 (WAL sentinel) -> Phase 2 I/O redesign.
4) Phase 1 QW5 (locks) -> Phase 2 concurrency refactor.
5) Phase 2 outputs -> Phase 3 Metal 4 / FP16 / PQ.

### Risk mitigation by phase
- Phase 1: feature flags for lock/WAL changes; add WAL replay tests before merging.
- Phase 2: determinism suite runs in CI; memory pool stress tests; backpressure asserts.
- Phase 3: quality/recall evaluation gate; maintain FP32 and baseline search fallback.

## Appendix: Micro-optimizations
- Reuse `Data` buffers for chunk payload serialization.
- Replace temporary `Array` building with `UnsafeMutableBufferPointer` in hot loops.
- Avoid per-iteration `String` allocations in tokenization by caching scalar views.
- Precompute hash keys for LRU entries to reduce repeated hashing.
