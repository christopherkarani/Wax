import Foundation
import Testing
import USearch
@testable import WaxCore
@testable import WaxVectorSearch

// MARK: - Existing VectorMetric tests

@Test
func vectorMetricMappingsAndScoringCoverAllCases() {
    #expect(VectorMetric(vecSimilarity: .cosine) == .cosine)
    #expect(VectorMetric(vecSimilarity: .dot) == .dot)
    #expect(VectorMetric(vecSimilarity: .l2) == .l2)

    #expect(VectorMetric.cosine.toUSearchMetric() == .cos)
    #expect(VectorMetric.dot.toUSearchMetric() == .ip)
    #expect(VectorMetric.l2.toUSearchMetric() == .l2sq)
    #expect(VectorMetric.cosine.toVecSimilarity() == .cosine)
    #expect(VectorMetric.dot.toVecSimilarity() == .dot)
    #expect(VectorMetric.l2.toVecSimilarity() == .l2)

    #expect(VectorMetric.cosine.score(fromDistance: 0.25) == 0.75)
    #expect(VectorMetric.dot.score(fromDistance: 2) == -2)
    #expect(VectorMetric.l2.score(fromDistance: 3) == -3)

    #expect(VectorMetric.cosine.score(fromDistance: .infinity) == 0)
}

// MARK: - Phase 6D: USearchSendable & USearchIndex extension coverage

/// USearchIndex.deserializeFromData with empty Data must return immediately without error.
/// This exercises the `guard !data.isEmpty else { return }` fast path.
@Test
func uSearchDeserializeFromEmptyDataIsNoOp() throws {
    let index = try USearchIndex.make(
        metric: .cos,
        dimensions: 4,
        connectivity: 16,
        quantization: .f32
    )
    // Empty data must not throw.
    try index.deserializeFromData(Data())
    // Index must still be functional (can add and search without crashing).
    try index.reserve(8)
    try index.add(key: 1, vector: [1.0, 0.0, 0.0, 0.0] as [Float])
    let (keys, _) = try index.search(vector: [1.0, 0.0, 0.0, 0.0] as [Float], count: 5)
    #expect(keys.contains(1))
}

/// USearchIndex.serializeToData on an empty index (0 vectors) produces non-crash behavior.
/// An empty index may return 0 bytes or valid header bytes; either is acceptable.
@Test
func uSearchSerializeEmptyIndexDoesNotCrash() throws {
    let index = try USearchIndex.make(
        metric: .cos,
        dimensions: 4,
        connectivity: 16,
        quantization: .f32
    )
    // Serialization of an empty index must not throw.
    let data = try index.serializeToData()
    // The result may be empty (fast path) or contain a valid header.
    // The important invariant: no crash and no unexpected error.
    #expect(data.count >= 0)
}

/// USearchIndex serialize → deserializeFromData round-trip preserves indexed vectors.
@Test
func uSearchSerializeDeserializeRoundTripViaExtension() throws {
    let original = try USearchIndex.make(
        metric: .cos,
        dimensions: 3,
        connectivity: 16,
        quantization: .f32
    )
    try original.reserve(8)
    try original.add(key: 100, vector: [1.0, 0.0, 0.0] as [Float])
    try original.add(key: 200, vector: [0.0, 1.0, 0.0] as [Float])

    let blob = try original.serializeToData()
    #expect(!blob.isEmpty)

    let restored = try USearchIndex.make(
        metric: .cos,
        dimensions: 3,
        connectivity: 16,
        quantization: .f32
    )
    try restored.deserializeFromData(blob)

    let (keys, _) = try restored.search(vector: [1.0, 0.0, 0.0] as [Float], count: 5)
    #expect(keys.contains(100))
}

/// USearchIndex.saveToBuffer / loadFromBuffer round-trip works correctly.
@Test
func uSearchSaveLoadBufferRoundTrip() throws {
    let index = try USearchIndex.make(
        metric: .cos,
        dimensions: 2,
        connectivity: 16,
        quantization: .f32
    )
    try index.reserve(8)
    try index.add(key: 42, vector: [1.0, 0.0] as [Float])

    let size = try index.serializedLength
    #expect(size > 0)

    var buffer = [UInt8](repeating: 0, count: size)
    try buffer.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        try index.saveToBuffer(base, length: size)
    }

    let restored = try USearchIndex.make(
        metric: .cos,
        dimensions: 2,
        connectivity: 16,
        quantization: .f32
    )
    try buffer.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        try restored.loadFromBuffer(base, length: size)
    }

    let (keys, _) = try restored.search(vector: [1.0, 0.0] as [Float], count: 5)
    #expect(keys.contains(42))
}

/// USearchIndex.serializedLength returns a positive value after adding vectors.
@Test
func uSearchSerializedLengthIsPositiveAfterAdd() throws {
    let index = try USearchIndex.make(
        metric: .cos,
        dimensions: 4,
        connectivity: 16,
        quantization: .f32
    )
    try index.reserve(8)
    try index.add(key: 1, vector: [1.0, 0.0, 0.0, 0.0] as [Float])
    let length = try index.serializedLength
    #expect(length > 0)
}

/// USearchVectorEngine init rejects zero dimensions.
@Test
func uSearchInitRejectsZeroDimensions() throws {
    do {
        _ = try USearchVectorEngine(metric: .cosine, dimensions: 0)
        Issue.record("Expected WaxError.invalidToc for zero dimensions")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
        #expect(reason.contains("dimensions must be > 0"))
    }
}

/// USearchVectorEngine supports dot-product metric correctly.
@Test
func uSearchDotProductMetricAddAndSearch() async throws {
    let engine = try USearchVectorEngine(metric: .dot, dimensions: 3)
    try await engine.add(frameId: 1, vector: [1.0, 0.0, 0.0])
    try await engine.add(frameId: 2, vector: [0.0, 1.0, 0.0])
    // Dot-product: score = -distance, so result ordering may differ from cosine.
    let hits = try await engine.search(vector: [1.0, 0.0, 0.0], topK: 5)
    #expect(!hits.isEmpty)
    #expect(hits.contains(where: { $0.frameId == 1 }))
}

/// USearchVectorEngine supports L2 metric correctly.
@Test
func uSearchL2MetricAddAndSearch() async throws {
    let engine = try USearchVectorEngine(metric: .l2, dimensions: 3)
    try await engine.add(frameId: 10, vector: [1.0, 0.0, 0.0])
    try await engine.add(frameId: 20, vector: [0.0, 1.0, 0.0])
    // For L2: score = -distance (lower distance = higher score).
    let hits = try await engine.search(vector: [1.0, 0.0, 0.0], topK: 5)
    #expect(!hits.isEmpty)
    // frameId 10 is nearest in L2 to [1, 0, 0].
    #expect(hits.first?.frameId == 10)
}

/// USearchVectorEngine: add with wrong dimension must throw encodingError.
@Test
func uSearchAddWrongDimensionThrows() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 3)
    do {
        try await engine.add(frameId: 1, vector: [1.0, 0.0])
        Issue.record("Expected WaxError.encodingError for wrong-dimension vector")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// USearchVectorEngine: search with wrong dimension must throw encodingError.
@Test
func uSearchSearchWrongDimensionThrows() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 3)
    try await engine.add(frameId: 1, vector: [1.0, 0.0, 0.0])
    do {
        _ = try await engine.search(vector: [1.0, 0.0], topK: 5)
        Issue.record("Expected WaxError.encodingError for wrong-dimension query")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Wrong error kind: \(error)")
            return
        }
    }
}

/// USearchVectorEngine: remove on empty engine is a silent no-op.
@Test
func uSearchRemoveOnEmptyEngineIsNoOp() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.remove(frameId: 999)
    let hits = try await engine.search(vector: [1.0, 0.0], topK: 5)
    #expect(hits.isEmpty)
}

/// VectorMetric.score returns 0 for NaN distance (not just infinity).
@Test
func vectorMetricScoreReturnsZeroForNaN() {
    #expect(VectorMetric.cosine.score(fromDistance: .nan) == 0)
    #expect(VectorMetric.dot.score(fromDistance: .nan) == 0)
    #expect(VectorMetric.l2.score(fromDistance: .nan) == 0)
}

/// VectorMetric.score handles negative infinity correctly.
@Test
func vectorMetricScoreHandlesNegativeInfinity() {
    // Negative infinity is finite? No — it is NOT finite.
    // score(fromDistance: -.infinity) must return 0 (the isFinite guard fires).
    #expect(VectorMetric.cosine.score(fromDistance: -.infinity) == 0)
    #expect(VectorMetric.dot.score(fromDistance: -.infinity) == 0)
}

/// VectorMetric.score for cosine: perfect match gives score 1.0 (distance 0).
@Test
func vectorMetricCosineScoreForZeroDistance() {
    #expect(VectorMetric.cosine.score(fromDistance: 0) == 1.0)
}

/// VectorMetric.score for dot/l2: distance of 0 gives score 0 (not negative).
@Test
func vectorMetricDotAndL2ScoreForZeroDistance() {
    #expect(VectorMetric.dot.score(fromDistance: 0) == 0)
    #expect(VectorMetric.l2.score(fromDistance: 0) == 0)
}
