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
        #expect(Bool(false))
    } catch {
        // Expected.
    }

    try await wax.close()
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
        #expect(Bool(false))
    } catch {
        // Expected.
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
        #expect(Bool(false))
    } catch {
        // Expected.
    }

    try await wax.close()
    try FileManager.default.removeItem(at: tempDir)
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
        try await wax.close()
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
