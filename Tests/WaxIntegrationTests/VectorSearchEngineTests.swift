import Foundation
import Metal
import Testing
import Wax
import WaxVectorSearch

@Test func vectorEngineAddSearchRemoveRoundtrip() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    try await engine.add(frameId: 0, vector: [1.0, 0.0, 0.0, 0.0])
    try await engine.add(frameId: 1, vector: [0.0, 1.0, 0.0, 0.0])

    let hits = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
    #expect(!hits.isEmpty)
    #expect(hits.contains(where: { $0.frameId == 0 }))

    try await engine.remove(frameId: 0)
    let hits2 = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
    #expect(!hits2.contains(where: { $0.frameId == 0 }))
}

@Test func vectorEngineSerializeDeserializeRoundtripPreservesSearch() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    try await engine.add(frameId: 0, vector: [1.0, 0.0, 0.0, 0.0])
    try await engine.add(frameId: 1, vector: [0.0, 1.0, 0.0, 0.0])
    let blob = try await engine.serialize()
    #expect(!blob.isEmpty)

    let engine2 = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    try await engine2.deserialize(blob)

    let hits = try await engine2.search(vector: [0.0, 1.0, 0.0, 0.0], topK: 10)
    #expect(!hits.isEmpty)
    #expect(hits.contains(where: { $0.frameId == 1 }))
}

@Test func vectorEngineTiedScoresUseStableFrameIDOrdering() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 20, vector: [0.0, 1.0])
    try await engine.add(frameId: 10, vector: [0.0, 1.0])

    let hits = try await engine.search(vector: [1.0, 0.0], topK: 10)
    #expect(hits.count == 2)
    #expect(hits.map(\.frameId) == [10, 20])
}

@Test func metalVectorEngineAddBatchUpdatesExistingIdsCorrectly() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 10, vector: [1.0, 0.0])
    try await engine.add(frameId: 20, vector: [0.0, 1.0])

    // Update only frameId 20; bug would overwrite frameId 10 instead.
    try await engine.addBatch(frameIds: [20], vectors: [[0.7, 0.7]])

    let hits = try await engine.search(vector: [0.7, 0.7], topK: 1)
    #expect(hits.first?.frameId == 20)
}

@Test func metalVectorEngineTiedScoresUseStableFrameIDOrdering() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 20, vector: [0.0, 1.0])
    try await engine.add(frameId: 10, vector: [0.0, 1.0])

    let hits = try await engine.search(vector: [1.0, 0.0], topK: 10)
    #expect(hits.count == 2)
    #expect(hits.map(\.frameId) == [10, 20])
}

@Test func unifiedSearchFallsBackToUSearchWhenMetalCannotDeserialize() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let session = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)
    _ = try await session.putWithEmbedding(Data("First".utf8), embedding: [1.0, 0.0])
    try await session.commit()

    let request = SearchRequest(
        embedding: [1.0, 0.0],
        vectorEnginePreference: .metalPreferred,
        mode: .vectorOnly,
        topK: 5
    )
    let response = try await wax.search(request)
    #expect(response.results.contains(where: { $0.frameId == 0 }))

    try await wax.close()
    try FileManager.default.removeItem(at: tempDir)
}

@Test func vectorMathNormalizedCheck() {
    #expect(VectorMath.isNormalizedL2([1.0, 0.0, 0.0]))
    #expect(!VectorMath.isNormalizedL2([2.0, 0.0, 0.0]))
}

@Test func vectorSearchSessionAddThenRemoveBeforeCommitPersistsRemoval() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let session = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)

    let frameId = try await wax.put(Data("payload".utf8))
    try await session.add(frameId: frameId, vector: [1.0, 0.0])
    try await session.remove(frameId: frameId)
    try await session.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let session2 = try await reopened.enableVectorSearch(dimensions: 2, preference: .cpuOnly)
    let hits = try await session2.search(vector: [1.0, 0.0], topK: 10)
    #expect(!hits.contains(where: { $0.frameId == frameId }))
    try await reopened.close()
}

@Test func vectorSearchSessionCosineSearchNormalizesScaledQueries() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }

    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let session = try await wax.enableVectorSearch(metric: .cosine, dimensions: 2, preference: .metalPreferred)

    let frameA = try await wax.put(Data("a".utf8))
    let frameB = try await wax.put(Data("b".utf8))
    try await session.add(frameId: frameA, vector: [1.0, 0.0])
    try await session.add(frameId: frameB, vector: [0.0, 1.0])

    let unitHits = try await session.search(vector: [1.0, 0.0], topK: 2)
    let scaledHits = try await session.search(vector: [12.0, 0.0], topK: 2)

    #expect(unitHits.first?.frameId == frameA)
    #expect(scaledHits.first?.frameId == frameA)
    #expect(unitHits.first != nil)
    #expect(scaledHits.first != nil)
    if let unitScore = unitHits.first?.score, let scaledScore = scaledHits.first?.score {
        #expect(abs(unitScore - scaledScore) < 0.001)
    }

    try await session.commit()
    try await wax.close()
}

@Test func mv2sVecIndexPersistsAndReopens() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let session = try await wax.enableVectorSearch(dimensions: 4)

    _ = try await session.putWithEmbedding(Data("First".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
    _ = try await session.putWithEmbedding(Data("Second".utf8), embedding: [0.0, 1.0, 0.0, 0.0])
    try await session.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let session2 = try await reopened.enableVectorSearch(dimensions: 4)
    let hits = try await session2.search(vector: [0.9, 0.1, 0.0, 0.0], topK: 10)
    #expect(!hits.isEmpty)
    #expect(hits.contains(where: { $0.frameId == 0 }))

    let manifest = await reopened.committedVecIndexManifest()
    #expect(manifest != nil)
    let bytes = try await reopened.readCommittedVecIndexBytes()
    #expect(bytes?.isEmpty == false)

    try await reopened.close()

    let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    for name in files {
        #expect(!name.hasSuffix(".usearch"))
    }
    try FileManager.default.removeItem(at: tempDir)
}

@Test func committingEmbeddingsRequiresStagedVectorIndex() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let frameId = try await wax.put(Data("payload".utf8))
    try await wax.putEmbedding(frameId: frameId, vector: [1.0, 0.0, 0.0, 0.0])

    do {
        try await wax.commit()
        Issue.record("Expected error when committing embeddings without staged vector index")
    } catch {
        // Expected: vector index must be staged before committing embeddings
    }

    do {
        try await wax.close()
        Issue.record("Expected close to propagate auto-commit failure")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("vector index must be staged before committing embeddings"))
    }
    try FileManager.default.removeItem(at: tempDir)
}

@Test func putEmbeddingRejectsMismatchedDimensionAgainstCommittedVecIndex() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    do {
        let wax = try await Wax.create(at: fileURL)
        let session = try await wax.enableVectorSearch(dimensions: 4)
        _ = try await session.putWithEmbedding(Data("payload".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
        try await session.commit()
        try await wax.close()
    }

    let reopened = try await Wax.open(at: fileURL)
    do {
        try await reopened.putEmbedding(frameId: 0, vector: [1, 0, 0, 0, 0])
        Issue.record("Expected error for dimension mismatch against committed vec index")
    } catch {
        // Expected: dimension mismatch vs committed vec index
    }
    try await reopened.close()
    try FileManager.default.removeItem(at: tempDir)
}

@Test func stageVecIndexRejectsPendingEmbeddingDimensionMismatch() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let frameId = try await wax.put(Data("payload".utf8))
    try await wax.putEmbedding(frameId: frameId, vector: [1.0, 0.0, 0.0, 0.0])

    do {
        try await wax.stageVecIndexForNextCommit(bytes: Data([0x01]), vectorCount: 0, dimension: 5, similarity: .cosine)
        Issue.record("Expected error for pending embedding dimension mismatch vs staged vec index")
    } catch {
        // Expected: pending embedding dimension mismatch
    }

    do {
        try await wax.close()
        Issue.record("Expected close to propagate auto-commit failure")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("vector index must be staged before committing embeddings"))
    }
    try FileManager.default.removeItem(at: tempDir)
}

@Test func commitRejectsStaleStagedVectorIndexWhenPendingEmbeddingsChange() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)

    let frame0 = try await wax.put(Data("first".utf8))
    try await wax.putEmbedding(frameId: frame0, vector: [1.0, 0.0, 0.0, 0.0])
    try await wax.stageVecIndexForNextCommit(
        bytes: Data([0x01]),
        vectorCount: 1,
        dimension: 4,
        similarity: .cosine
    )

    let frame1 = try await wax.put(Data("second".utf8))
    try await wax.putEmbedding(frameId: frame1, vector: [0.0, 1.0, 0.0, 0.0])

    do {
        try await wax.commit()
        Issue.record("Expected error for stale staged vector index")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("vector index is stale"))
    }

    do {
        try await wax.close()
        Issue.record("Expected close to propagate stale auto-commit failure")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("vector index is stale"))
    }
}

// MARK: - Phase 6A: USearch batch, streaming, deserialization coverage

/// addBatch with an empty array must return immediately without mutating state.
@Test func uSearchAddBatchEmptyFastPathLeavesEngineUnchanged() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)

    // Empty call — must not throw and must not add any vector.
    try await engine.addBatch(frameIds: [], vectors: [])

    // Engine should still be empty; search returns no results.
    let hits = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 5)
    #expect(hits.isEmpty)
}

/// addBatch with mismatched array lengths must throw an encodingError.
@Test func uSearchAddBatchMismatchedLengthsThrows() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    do {
        try await engine.addBatch(
            frameIds: [1, 2],
            vectors: [[1.0, 0.0, 0.0, 0.0]]   // only one vector for two IDs
        )
        Issue.record("Expected WaxError.encodingError for mismatched array lengths")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// addBatch on an empty engine takes the fast path (no remove calls), then
/// correctly upserts on a subsequent call that targets an already-indexed key.
@Test func uSearchAddBatchEmptyFastPathThenUpdateExistingKey() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)

    // Fast path: engine is empty, no remove logic runs.
    try await engine.addBatch(frameIds: [10, 20], vectors: [[1.0, 0.0], [0.0, 1.0]])

    // Standard path: engine is non-empty, so existing key 20 is removed first.
    try await engine.addBatch(frameIds: [20], vectors: [[0.7, 0.3]])

    // After upsert, searching near [0.7, 0.3] should rank frameId 20 highest.
    let hits = try await engine.search(vector: [0.7, 0.3], topK: 2)
    #expect(hits.first?.frameId == 20)
    // frameId 10 must also still be present (not clobbered).
    #expect(hits.contains(where: { $0.frameId == 10 }))
}

/// addBatchStreaming with count > chunkSize exercises the chunked code path.
@Test func uSearchAddBatchStreamingChunkedPathAddsAllVectors() async throws {
    let dims = 2
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: dims)

    // Build 300 unique frame IDs; this exceeds the default chunkSize of 256.
    let count = 300
    let frameIds = (0..<count).map { UInt64($0) }
    // All vectors point in the same direction so exact scores are predictable.
    let vectors = Array(repeating: [1.0, 0.0] as [Float], count: count)

    try await engine.addBatchStreaming(frameIds: frameIds, vectors: vectors, chunkSize: 64)

    // Request more than we added — must return exactly `count` results without crashing.
    let hits = try await engine.search(vector: [1.0, 0.0], topK: count + 50)
    #expect(hits.count == count)
    // Every frame ID must appear exactly once.
    let returnedIds = Set(hits.map(\.frameId))
    #expect(returnedIds.count == count)
    for id in frameIds {
        #expect(returnedIds.contains(id))
    }
}

/// addBatchStreaming with count <= chunkSize delegates to addBatch (single chunk).
@Test func uSearchAddBatchStreamingSmallBatchDelegatesToAddBatch() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    // 10 vectors, chunkSize 256 → single-chunk delegation.
    let frameIds = (0..<10).map { UInt64($0) }
    let vectors = Array(repeating: [1.0, 0.0] as [Float], count: 10)
    try await engine.addBatchStreaming(frameIds: frameIds, vectors: vectors, chunkSize: 256)

    let hits = try await engine.search(vector: [1.0, 0.0], topK: 20)
    #expect(hits.count == 10)
}

/// search on a completely empty engine returns an empty array (not a crash or throw).
@Test func uSearchSearchOnEmptyEngineReturnsEmpty() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    let hits = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
    #expect(hits.isEmpty)
}

/// search with topK larger than the number of indexed vectors returns all vectors.
@Test func uSearchSearchTopKExceedingCountReturnsAll() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    try await engine.add(frameId: 1, vector: [1.0, 0.0, 0.0, 0.0])
    try await engine.add(frameId: 2, vector: [0.0, 1.0, 0.0, 0.0])
    try await engine.add(frameId: 3, vector: [0.0, 0.0, 1.0, 0.0])

    // Request 1000 results when only 3 exist — must not crash.
    let hits = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 1000)
    #expect(hits.count == 3)
    #expect(Set(hits.map(\.frameId)) == [1, 2, 3])
}

/// Search results with identical scores must use ascending frameId as tiebreaker
/// and must be deterministic across repeated calls.
@Test func uSearchSearchResultOrderIsDeterministic() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    // All three vectors are identical, so distances are tied.
    try await engine.add(frameId: 30, vector: [1.0, 0.0])
    try await engine.add(frameId: 10, vector: [1.0, 0.0])
    try await engine.add(frameId: 20, vector: [1.0, 0.0])

    let hits1 = try await engine.search(vector: [1.0, 0.0], topK: 10)
    let hits2 = try await engine.search(vector: [1.0, 0.0], topK: 10)

    // Tiebreaker: ascending frameId.
    #expect(hits1.map(\.frameId) == [10, 20, 30])
    // Results must be identical across calls.
    #expect(hits1.map(\.frameId) == hits2.map(\.frameId))
}

/// serialize / deserialize round-trip preserves all indexed vectors and their scores.
@Test func uSearchSerializeDeserializeRoundTrip() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 3)
    try await engine.add(frameId: 100, vector: [1.0, 0.0, 0.0])
    try await engine.add(frameId: 200, vector: [0.0, 1.0, 0.0])
    try await engine.add(frameId: 300, vector: [0.0, 0.0, 1.0])

    let blob = try await engine.serialize()
    #expect(!blob.isEmpty)

    let engine2 = try USearchVectorEngine(metric: .cosine, dimensions: 3)
    try await engine2.deserialize(blob)

    // All three frame IDs must be retrievable.
    let hits = try await engine2.search(vector: [1.0, 0.0, 0.0], topK: 10)
    #expect(hits.count == 3)
    #expect(hits.first?.frameId == 100)    // best cosine match

    let hits2 = try await engine2.search(vector: [0.0, 1.0, 0.0], topK: 10)
    #expect(hits2.first?.frameId == 200)

    let hits3 = try await engine2.search(vector: [0.0, 0.0, 1.0], topK: 10)
    #expect(hits3.first?.frameId == 300)
}

/// deserialize must reject data whose embedded dimension differs from the engine's dimension.
@Test func uSearchDeserializeDimensionMismatchThrows() async throws {
    // Build and serialize a 4-D engine.
    let src = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    try await src.add(frameId: 1, vector: [1.0, 0.0, 0.0, 0.0])
    let blob = try await src.serialize()

    // Attempt to deserialize into a 2-D engine — must throw invalidToc.
    let dst = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    do {
        try await dst.deserialize(blob)
        Issue.record("Expected WaxError.invalidToc for dimension mismatch on deserialize")
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// remove followed by search must confirm the removed frame ID is no longer returned.
@Test func uSearchRemoveThenSearchConfirmsAbsence() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 4)
    try await engine.add(frameId: 1, vector: [1.0, 0.0, 0.0, 0.0])
    try await engine.add(frameId: 2, vector: [0.9, 0.1, 0.0, 0.0])

    // Remove frameId 1 — the perfect match for the query below.
    try await engine.remove(frameId: 1)

    let hits = try await engine.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
    #expect(!hits.contains(where: { $0.frameId == 1 }))
    // The other vector must still be present.
    #expect(hits.contains(where: { $0.frameId == 2 }))
}

/// Adding more vectors than initialReserve (64) exercises the capacity-doubling path.
@Test func uSearchCapacityGrowthBeyondInitialReserve() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    // initialReserve is 64; add 70 vectors to force at least one doubling.
    let count = 70
    for i in 0..<count {
        // Vary the vectors so we get meaningful nearest-neighbour results.
        let angle = Float(i) / Float(count)
        try await engine.add(frameId: UInt64(i), vector: [angle, 1.0 - angle])
    }
    // All vectors must be retrievable.
    let hits = try await engine.search(vector: [0.5, 0.5], topK: count + 10)
    #expect(hits.count == count)
}

/// stageForCommit must write the serialized index into a real Wax store
/// so that a freshly opened store can reload it.
@Test func uSearchStageForCommitPersistsIndex() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("stage.mv2s")
    let wax = try await Wax.create(at: fileURL)

    // Build a standalone engine, add some vectors, stage, then commit.
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 42, vector: [1.0, 0.0])
    try await engine.add(frameId: 99, vector: [0.0, 1.0])

    // Stage — this calls wax.stageVecIndexForNextCommit internally.
    try await engine.stageForCommit(into: wax)
    try await wax.commit()
    try await wax.close()

    // Re-open and verify the committed index is loadable and searchable.
    let reopened = try await Wax.open(at: fileURL)
    let bytes = try await reopened.readCommittedVecIndexBytes()
    #expect(bytes?.isEmpty == false)

    let engine2 = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    if let indexBytes = bytes {
        try await engine2.deserialize(indexBytes)
    }
    let hits = try await engine2.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.first?.frameId == 42)
    try await reopened.close()
}

/// stageForCommit called on a clean (non-dirty) engine must be a no-op.
@Test func uSearchStageForCommitIsNoOpWhenClean() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("noop.mv2s")
    let wax = try await Wax.create(at: fileURL)

    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    // Add and then immediately serialize/deserialize to reset dirty flag.
    try await engine.add(frameId: 1, vector: [1.0, 0.0])
    let blob = try await engine.serialize()
    let engine2 = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await engine2.deserialize(blob)

    // engine2.dirty is false after deserialization; stageForCommit must be a no-op
    // (no staged vec index → commit should succeed without complaining about embeddings).
    try await engine2.stageForCommit(into: wax)

    // Commit with no staged index and no pending embeddings must succeed.
    try await wax.commit()
    try await wax.close()

    // If we reach here the no-op path executed correctly.
    let manifest = await (try? Wax.open(at: fileURL))?.committedVecIndexManifest()
    #expect(manifest == nil)   // nothing was staged, so no committed vec index
}

/// addBatchStreaming with an empty array must be a fast-path no-op.
@Test func uSearchAddBatchStreamingEmptyFastPath() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.addBatchStreaming(frameIds: [], vectors: [], chunkSize: 64)
    let hits = try await engine.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.isEmpty)
}

@Test func crashRecoveryAllowsVectorCommitWithoutReprovidingEmbeddings() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    do {
        let wax = try await Wax.create(at: fileURL)
        let session = try await wax.enableVectorSearch(dimensions: 4)
        _ = try await session.putWithEmbedding(Data("First".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
        // Simulate crash by closing without commit.
        do {
            try await wax.close()
            Issue.record("Expected close to propagate auto-commit failure")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("vector index must be staged before committing embeddings"))
        }
    }

    do {
        let reopened = try await Wax.open(at: fileURL)
        let session2 = try await reopened.enableVectorSearch(dimensions: 4)
        let precommit = try await session2.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
        #expect(!precommit.isEmpty)
        #expect(precommit.contains(where: { $0.frameId == 0 }))
        try await session2.commit()
        try await reopened.close()
    }

    let reopened2 = try await Wax.open(at: fileURL)
    let session3 = try await reopened2.enableVectorSearch(dimensions: 4)
    let hits = try await session3.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 10)
    #expect(!hits.isEmpty)
    #expect(hits.contains(where: { $0.frameId == 0 }))
    try await reopened2.close()

    try FileManager.default.removeItem(at: tempDir)
}
