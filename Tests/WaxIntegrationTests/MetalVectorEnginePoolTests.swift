#if canImport(Metal)
import Metal
import Testing
import Wax
@testable import WaxVectorSearch

// MARK: - Existing buffer-pool tests

@Test
func metalSearchReusesTransientBuffers() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 1, vector: [1.0, 0.0])

    _ = try await engine.search(vector: [1.0, 0.0], topK: 1)
    let first = await engine.debugBufferPoolStats()

    _ = try await engine.search(vector: [1.0, 0.0], topK: 1)
    let second = await engine.debugBufferPoolStats()

    #expect(second.transientAllocations == first.transientAllocations)
    #expect(second.reuseCount >= first.reuseCount)
}

@Test
func metalTransientPoolEvictsOversizedBuffers() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)

    for id in 0..<2_048 {
        try await engine.add(frameId: UInt64(id), vector: [1.0, 0.0])
    }
    _ = try await engine.search(vector: [1.0, 0.0], topK: 1)

    for id in 100..<2_048 {
        try await engine.remove(frameId: UInt64(id))
    }

    _ = try await engine.search(vector: [1.0, 0.0], topK: 1)
    let stats = await engine.debugBufferPoolStats()
    #expect(stats.pooledBuffers <= 8)
    #expect(stats.maxPooledCapacity <= 200)
}

@Test
func metalAddBatchUpdatesExistingFrameIdsWithoutDuplicates() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)

    try await engine.addBatch(
        frameIds: [1, 2],
        vectors: [[1.0, 0.0], [0.0, 1.0]]
    )
    try await engine.addBatch(
        frameIds: [1],
        vectors: [[-1.0, 0.0]]
    )

    let results = try await engine.search(vector: [1.0, 0.0], topK: 10)
    #expect(results.count == 2)
    #expect(results.first?.frameId == 2)
}

@Test
func metalTransientPoolStaysBoundedUnderLongRunSearchChurn() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)

    for id in 0..<1_024 {
        let vector: [Float] = id % 2 == 0 ? [1.0, 0.0] : [0.0, 1.0]
        try await engine.add(frameId: UInt64(id), vector: vector)
    }

    _ = try await engine.search(vector: [1.0, 0.0], topK: 8)
    let warm = await engine.debugBufferPoolStats()

    for iteration in 0..<256 {
        let topK = (iteration % 3 == 0) ? 8 : ((iteration % 3 == 1) ? 16 : 24)
        _ = try await engine.search(vector: [1.0, 0.0], topK: topK)
    }

    let final = await engine.debugBufferPoolStats()
    #expect(final.pooledBuffers <= 8)
    #expect(final.maxPooledCapacity <= 1_024)
    #expect(final.transientAllocations - warm.transientAllocations <= 12)
    #expect(final.reuseCount > warm.reuseCount)
}

// MARK: - Phase 6B: MetalVectorEngine coverage

/// MetalVectorEngine init rejects dimensions <= 0.
@Test
func metalInitRejectsZeroDimensions() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    do {
        _ = try MetalVectorEngine(metric: .cosine, dimensions: 0)
        Issue.record("Expected WaxError.invalidToc for zero dimensions")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("dimensions must be > 0"))
    }
}

/// MetalVectorEngine init rejects non-cosine metrics.
@Test
func metalInitRejectsNonCosineMetric() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    do {
        _ = try MetalVectorEngine(metric: .dot, dimensions: 4)
        Issue.record("Expected WaxError.invalidToc for non-cosine metric")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("cosine"))
    }
}

/// MetalVectorEngine selects the SIMD8 kernel when dimensions >= 384.
/// Verified indirectly: the engine must be constructable and searchable with 384-dim vectors.
@Test
func metalSIMD8KernelUsedFor384DimVectors() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    // 384 is exactly the SIMD8 threshold; the engine should use the SIMD8 pipeline when available.
    let dims = 384
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: dims)
    #expect(await engine.dimensions == dims)

    var v1 = [Float](repeating: 0, count: dims)
    v1[0] = 1.0
    var v2 = [Float](repeating: 0, count: dims)
    v2[1] = 1.0

    try await engine.add(frameId: 1, vector: v1)
    try await engine.add(frameId: 2, vector: v2)

    let hits = try await engine.search(vector: v1, topK: 2)
    #expect(hits.count == 2)
    // frameId 1 is the best cosine match for v1.
    #expect(hits.first?.frameId == 1)
}

/// MetalVectorEngine with dimensions below the threshold uses the SIMD4 pipeline.
@Test
func metalSIMD4KernelUsedFor383DimVectors() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let dims = 383
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: dims)
    #expect(await engine.dimensions == dims)

    var v = [Float](repeating: 0, count: dims)
    v[0] = 1.0
    try await engine.add(frameId: 42, vector: v)

    let hits = try await engine.search(vector: v, topK: 1)
    #expect(hits.first?.frameId == 42)
}

/// addBatch with mismatched frameIds/vectors counts must throw encodingError.
@Test
func metalAddBatchMismatchedCountsThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await engine.addBatch(frameIds: [1, 2], vectors: [[1.0, 0.0]])
        Issue.record("Expected WaxError.encodingError for mismatched batch counts")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// addBatch with empty arrays must be a no-op (no throw, no state change).
@Test
func metalAddBatchEmptyIsNoOp() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.addBatch(frameIds: [], vectors: [])
    let hits = try await engine.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.isEmpty)
}

/// addBatch with dimension-mismatched vectors must throw encodingError.
@Test
func metalAddBatchWrongDimensionThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await engine.addBatch(frameIds: [1], vectors: [[1.0, 0.0, 0.0]])
        Issue.record("Expected WaxError.encodingError for dimension mismatch in batch")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// addBatchStreaming with count > chunkSize exercises the chunked code path.
@Test
func metalAddBatchStreamingChunkedPathAddsAllVectors() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let dims = 2
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: dims)
    let count = 300
    let frameIds = (0..<count).map { UInt64($0) }
    let vectors = Array(repeating: [1.0, 0.0] as [Float], count: count)

    try await engine.addBatchStreaming(frameIds: frameIds, vectors: vectors, chunkSize: 64)

    let hits = try await engine.search(vector: [1.0, 0.0], topK: count + 50)
    #expect(hits.count == count)
    let returnedIds = Set(hits.map(\.frameId))
    for id in frameIds {
        #expect(returnedIds.contains(id))
    }
}

/// addBatchStreaming with count <= chunkSize delegates to addBatch (single chunk).
@Test
func metalAddBatchStreamingSmallBatchDelegatesToAddBatch() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    let frameIds = (0..<10).map { UInt64($0) }
    let vectors = Array(repeating: [1.0, 0.0] as [Float], count: 10)
    try await engine.addBatchStreaming(frameIds: frameIds, vectors: vectors, chunkSize: 256)

    let hits = try await engine.search(vector: [1.0, 0.0], topK: 20)
    #expect(hits.count == 10)
}

/// addBatchStreaming with empty arrays must be a no-op.
@Test
func metalAddBatchStreamingEmptyIsNoOp() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.addBatchStreaming(frameIds: [], vectors: [], chunkSize: 64)
    let hits = try await engine.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.isEmpty)
}

/// addBatchStreaming with mismatched array lengths must throw.
@Test
func metalAddBatchStreamingMismatchedLengthsThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await engine.addBatchStreaming(frameIds: [1, 2], vectors: [[1.0, 0.0]], chunkSize: 64)
        Issue.record("Expected WaxError.encodingError for mismatched streaming batch lengths")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// search on an empty MetalVectorEngine returns an empty array without throwing.
@Test
func metalSearchOnEmptyEngineReturnsEmpty() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 4)
    let hits = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
    #expect(hits.isEmpty)
}

/// remove on an empty engine must be a silent no-op (not a crash or throw).
@Test
func metalRemoveOnEmptyEngineIsNoOp() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.remove(frameId: 999)
    let hits = try await engine.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.isEmpty)
}

/// remove of a non-existent frameId in a non-empty engine must not mutate the count.
@Test
func metalRemoveNonExistentFrameIdIsNoOp() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 1, vector: [1.0, 0.0])
    try await engine.remove(frameId: 999)
    let hits = try await engine.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.count == 1)
    #expect(hits.first?.frameId == 1)
}

/// serialize / deserialize round-trip preserves all indexed vectors and their search results.
@Test
func metalSerializeDeserializeRoundTrip() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 3)
    try await engine.add(frameId: 10, vector: [1.0, 0.0, 0.0])
    try await engine.add(frameId: 20, vector: [0.0, 1.0, 0.0])
    try await engine.add(frameId: 30, vector: [0.0, 0.0, 1.0])

    let blob = try await engine.serialize()
    #expect(!blob.isEmpty)

    let engine2 = try MetalVectorEngine(metric: .cosine, dimensions: 3)
    try await engine2.deserialize(blob)

    let hits = try await engine2.search(vector: [1.0, 0.0, 0.0], topK: 3)
    #expect(hits.count == 3)
    #expect(hits.first?.frameId == 10)

    let hits2 = try await engine2.search(vector: [0.0, 1.0, 0.0], topK: 3)
    #expect(hits2.first?.frameId == 20)

    let hits3 = try await engine2.search(vector: [0.0, 0.0, 1.0], topK: 3)
    #expect(hits3.first?.frameId == 30)
}

/// deserialize must reject data that is too small.
@Test
func metalDeserializeTooSmallThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await engine.deserialize(Data([0x01, 0x02, 0x03]))
        Issue.record("Expected WaxError.invalidToc for too-small data")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("too small"))
    }
}

/// deserialize must reject data with a wrong magic header.
@Test
func metalDeserializeMagicMismatchThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    // Build a 36-byte payload with bad magic.
    var bad = Data(repeating: 0, count: 36)
    bad[0] = 0xDE; bad[1] = 0xAD; bad[2] = 0xBE; bad[3] = 0xEF
    do {
        try await engine.deserialize(bad)
        Issue.record("Expected WaxError.invalidToc for magic mismatch")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("magic mismatch"))
    }
}

/// deserialize must reject a payload with an unsupported version field.
@Test
func metalDeserializeUnsupportedVersionThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    // Correct magic, version = 2 (unsupported).
    var bad = Data(repeating: 0, count: 36)
    // Magic: "MV2V"
    bad[0] = 0x4D; bad[1] = 0x56; bad[2] = 0x32; bad[3] = 0x56
    // Version = 2 (little-endian)
    bad[4] = 0x02; bad[5] = 0x00
    do {
        try await engine.deserialize(bad)
        Issue.record("Expected WaxError.invalidToc for unsupported version")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("Unsupported Metal segment version"))
    }
}

/// deserialize must reject a payload with an unsupported encoding byte.
@Test
func metalDeserializeUnsupportedEncodingThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    // Correct magic, version = 1, encoding = 99 (unsupported).
    var bad = Data(repeating: 0, count: 36)
    bad[0] = 0x4D; bad[1] = 0x56; bad[2] = 0x32; bad[3] = 0x56 // magic
    bad[4] = 0x01; bad[5] = 0x00 // version = 1
    bad[6] = 99 // encoding: invalid
    do {
        try await engine.deserialize(bad)
        Issue.record("Expected WaxError.invalidToc for unsupported encoding")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("Unsupported Metal segment encoding"))
    }
}

/// deserialize must reject a payload where dimension does not match the engine's dimension.
@Test
func metalDeserializeDimensionMismatchThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    // Serialize a 3-dim engine, then try to load it into a 2-dim engine.
    let src = try MetalVectorEngine(metric: .cosine, dimensions: 3)
    try await src.add(frameId: 1, vector: [1.0, 0.0, 0.0])
    let blob = try await src.serialize()

    let dst = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await dst.deserialize(blob)
        Issue.record("Expected WaxError.invalidToc for dimension mismatch")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("Dimension mismatch"))
    }
}

/// deserialize must reject a payload where reserved bytes are non-zero.
@Test
func metalDeserializeNonZeroReservedBytesThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    // Build a minimal valid Metal header but with non-zero reserved bytes at offset 28..35.
    // Layout: magic(4) version(2) encoding(1) similarity(1) dims(4) vectorCount(8) vecDataLen(8) reserved(8)
    var data = Data(count: 36)
    // Magic
    data[0] = 0x4D; data[1] = 0x56; data[2] = 0x32; data[3] = 0x56
    // Version = 1 LE
    data[4] = 0x01; data[5] = 0x00
    // Encoding = 2 (Metal)
    data[6] = 0x02
    // Similarity = 0 (cosine)
    data[7] = 0x00
    // Dimensions = 2 LE uint32
    data[8] = 0x02; data[9] = 0x00; data[10] = 0x00; data[11] = 0x00
    // Vector count = 0 LE uint64
    // bytes 12..19 are zero (already zero)
    // Vec data length = 0 LE uint64
    // bytes 20..27 are zero (already zero)
    // Reserved bytes 28..35: set to non-zero
    data[28] = 0xFF
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await engine.deserialize(data)
        Issue.record("Expected WaxError.invalidToc for non-zero reserved bytes")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("reserved bytes must be zero"))
    }
}

/// stageForCommit on a dirty engine serializes and writes to Wax.
@Test
func metalStageForCommitPersistsDirtyEngine() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("metal_stage.mv2s")
    let wax = try await Wax.create(at: fileURL)

    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 1, vector: [1.0, 0.0])
    try await engine.add(frameId: 2, vector: [0.0, 1.0])

    try await engine.stageForCommit(into: wax)
    try await wax.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let bytes = try await reopened.readCommittedVecIndexBytes()
    #expect(bytes?.isEmpty == false)
    try await reopened.close()
}

/// stageForCommit on a clean (non-dirty) engine must be a silent no-op.
@Test
func metalStageForCommitIsNoOpWhenClean() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("metal_noop.mv2s")
    let wax = try await Wax.create(at: fileURL)

    // Serialize and deserialize resets dirty to false.
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 1, vector: [1.0, 0.0])
    let blob = try await engine.serialize()

    let engine2 = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine2.deserialize(blob)

    // engine2 is clean; stageForCommit must be a no-op.
    try await engine2.stageForCommit(into: wax)
    // Commit with no staged index and no pending embeddings must succeed.
    try await wax.commit()
    try await wax.close()

    // No vec index should have been committed.
    let manifest = await (try? Wax.open(at: fileURL))?.committedVecIndexManifest()
    #expect(manifest == nil)
}

/// Buffer pool: after multiple searches, reuseCount increases while allocation count remains stable.
@Test
func metalBufferPoolReuseCountIncreasesWithSearches() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 4)
    try await engine.add(frameId: 1, vector: [1.0, 0.0, 0.0, 0.0])
    try await engine.add(frameId: 2, vector: [0.0, 1.0, 0.0, 0.0])

    // Warm the pool.
    _ = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 2)
    let before = await engine.debugBufferPoolStats()

    for _ in 0..<10 {
        _ = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 2)
    }
    let after = await engine.debugBufferPoolStats()

    // Allocations must not have grown; reuse must have grown.
    #expect(after.transientAllocations == before.transientAllocations)
    #expect(after.reuseCount > before.reuseCount)
}

/// Capacity growth beyond initialReserve (64) exercises the buffer-doubling path.
@Test
func metalCapacityGrowthBeyondInitialReserve() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    let count = 70 // > initialReserve (64)
    for i in 0..<count {
        let angle = Float(i) / Float(count)
        try await engine.add(frameId: UInt64(i), vector: [angle, 1.0 - angle])
    }
    let hits = try await engine.search(vector: [0.5, 0.5], topK: count + 10)
    #expect(hits.count == count)
}

/// remove of the middle element correctly shifts the remaining frameIds.
@Test
func metalRemoveMiddleElementShiftsFrameIds() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 10, vector: [1.0, 0.0])
    try await engine.add(frameId: 20, vector: [0.0, 1.0])
    try await engine.add(frameId: 30, vector: [0.7, 0.7])

    try await engine.remove(frameId: 20)

    let hits = try await engine.search(vector: [1.0, 0.0], topK: 10)
    #expect(hits.count == 2)
    #expect(!hits.contains(where: { $0.frameId == 20 }))
    #expect(hits.contains(where: { $0.frameId == 10 }))
    #expect(hits.contains(where: { $0.frameId == 30 }))
}

/// Updating an existing frameId via add does not create a duplicate entry.
@Test
func metalAddUpdatesExistingFrameIdInPlace() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 1, vector: [1.0, 0.0])
    try await engine.add(frameId: 2, vector: [0.0, 1.0])

    // Overwrite frameId 1 with a vector close to frameId 2.
    try await engine.add(frameId: 1, vector: [0.1, 0.9])

    let hits = try await engine.search(vector: [0.0, 1.0], topK: 5)
    // Should return exactly 2 results (no duplicates).
    #expect(hits.count == 2)
    // frameId 1's updated vector is closer to [0, 1] than frameId 2 only marginally;
    // the important invariant is no duplicates.
    let frameIds = Set(hits.map(\.frameId))
    #expect(frameIds == [1, 2])
}

/// add rejects a vector with the wrong dimension.
@Test
func metalAddWrongDimensionThrows() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await engine.add(frameId: 1, vector: [1.0, 0.0, 0.0])
        Issue.record("Expected WaxError.encodingError for wrong-dimension vector")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// debugBufferPoolStats returns sane initial values on a fresh engine.
@Test
func metalDebugBufferPoolStatsInitialState() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    let stats = await engine.debugBufferPoolStats()
    // The pool is pre-seeded with one buffer in init, so allocations start at 0.
    #expect(stats.transientAllocations == 0)
    #expect(stats.reuseCount == 0)
    #expect(stats.pooledBuffers >= 1)
}

/// USearchVectorEngine can consume a Metal-encoded payload produced by MetalVectorEngine.
@Test
func uSearchEngineDeserializesMetalPayload() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let metal = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await metal.add(frameId: 7, vector: [1.0, 0.0])
    try await metal.add(frameId: 8, vector: [0.0, 1.0])
    let blob = try await metal.serialize()

    let usearch = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await usearch.deserialize(blob)

    let hits = try await usearch.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.contains(where: { $0.frameId == 7 }))
    #expect(hits.contains(where: { $0.frameId == 8 }))
}

#endif
