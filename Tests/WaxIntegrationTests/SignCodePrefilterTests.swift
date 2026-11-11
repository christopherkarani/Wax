import Foundation
import Testing
import WaxCore
@testable import WaxVectorSearch

// MARK: - Fixtures

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform float in [-1, 1).
    mutating func nextUnitFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24) * 2 - 1
    }
}

private func normalized(_ vector: [Float]) -> [Float] {
    let norm = vector.reduce(Float.zero) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? vector.map { $0 / norm } : vector
}

/// Rows on a 16-dimensional latent subspace plus isotropic noise, normalized, so
/// neighborhoods form a continuum the way text embeddings do. When `unitNorm` is false
/// each row is scaled by a magnitude in [0.5, 2) (unnormalized dot product).
private func embeddingLikeRows(count: Int, dimensions: Int, unitNorm: Bool, seed: UInt64) -> [[Float]] {
    let latent = 16
    var random = SeededRandom(seed: seed)
    var basis: [[Float]] = []
    for _ in 0..<latent {
        basis.append((0..<dimensions).map { _ in random.nextUnitFloat() })
    }
    var rows: [[Float]] = []
    rows.reserveCapacity(count)
    for _ in 0..<count {
        var point = [Float](repeating: 0, count: dimensions)
        for axis in 0..<latent {
            let weight: Float = random.nextUnitFloat()
            for index in 0..<dimensions {
                point[index] += weight * basis[axis][index]
            }
        }
        for index in 0..<dimensions {
            let noise: Float = 0.3 * random.nextUnitFloat()
            point[index] += noise
        }
        point = normalized(point)
        if !unitNorm {
            let unit: Float = random.nextUnitFloat() + 1
            let magnitude: Float = 0.5 + 0.75 * unit
            point = point.map { $0 * magnitude }
        }
        rows.append(point)
    }
    return rows
}

private func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
    var total: Float = 0
    for index in lhs.indices {
        total += lhs[index] * rhs[index]
    }
    return total
}

private struct ScoredRow {
    let row: Int
    let score: Float
}

/// Exact top-`k` row indices by dot product, ties to the lower row.
private func exactTopRows(_ rows: [[Float]], query: [Float], k: Int) -> [Int] {
    var scored: [ScoredRow] = []
    scored.reserveCapacity(rows.count)
    for row in rows.indices {
        scored.append(ScoredRow(row: row, score: dot(rows[row], query)))
    }
    scored.sort { (lhs: ScoredRow, rhs: ScoredRow) -> Bool in
        lhs.score == rhs.score ? lhs.row < rhs.row : lhs.score > rhs.score
    }
    return scored.prefix(k).map { (entry: ScoredRow) -> Int in entry.row }
}

private func queries(near rows: [[Float]], count: Int, seed: UInt64) -> [[Float]] {
    var random = SeededRandom(seed: seed)
    var probes: [[Float]] = []
    for index in 0..<count {
        let base: [Float] = rows[(index * 7_919) % rows.count]
        var probe: [Float] = []
        probe.reserveCapacity(base.count)
        for value in base {
            let noise: Float = 0.05 * random.nextUnitFloat()
            probe.append(value + noise)
        }
        probes.append(normalized(probe))
    }
    return probes
}

// MARK: - SignCodeIndex

/// The recall checks below spend seconds of CPU (24 s for the 52k store in debug) without
/// suspending. Run on the cooperative pool, each held one of a CI runner's three threads
/// and starved every other test, so they run on a GCD thread and return what to check.
private func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await BlockingWork.run(work)
}

private struct ShortlistRecall: Sendable {
    var indexCount = 0
    var shortlistSizes: [Int] = []
    var found = 0
    var probeCount = 0
    var recall: Double { Double(found) / Double(probeCount * 10) }
}

private func shortlistRecall(rowCount: Int, unitNorm: Bool, seed: UInt64) -> ShortlistRecall {
    let dimensions = 128
    let rows = embeddingLikeRows(count: rowCount, dimensions: dimensions, unitNorm: unitNorm, seed: seed)
    let index = SignCodeIndex(dimensions: dimensions, rows: rows.flatMap { $0 })
    var result = ShortlistRecall(indexCount: index.count)
    let probes = queries(near: rows, count: 40, seed: seed + 1)
    result.probeCount = probes.count
    for query in probes {
        let shortlist = Set(index.candidates(for: query, limit: SignCodeIndex.candidateCount(topK: 10)))
        result.shortlistSizes.append(shortlist.count)
        result.found += exactTopRows(rows, query: query, k: 10).filter(shortlist.contains).count
    }
    return result
}

@Test("Sign-code shortlist keeps the true top 10 of embedding-like rows")
func signCodeShortlistKeepsTrueTopTen() async {
    let result = await offCooperativePool { shortlistRecall(rowCount: 8_000, unitNorm: true, seed: 0x5157) }
    #expect(result.indexCount == 8_000)
    #expect(result.shortlistSizes.allSatisfy { $0 == SignCodeIndex.minCandidates }, "\(result.shortlistSizes)")
    #expect(result.recall >= 0.99, "shortlist recall@10 \(result.recall)")
}

@Test("Sign-code shortlist scales magnitudes for unnormalized dot product")
func signCodeShortlistHandlesUnnormalizedRows() async {
    let result = await offCooperativePool { shortlistRecall(rowCount: 8_000, unitNorm: false, seed: 0xD07) }
    #expect(result.recall >= 0.99, "shortlist recall@10 \(result.recall)")
}

@Test("Sign-code index edits match an index encoded from the final rows")
func signCodeIndexEditsMatchFreshEncoding() {
    // 200 dims: not a multiple of 64 or 128, so the partial last word and the scalar
    // tail are both exercised.
    let dimensions = 200
    var rows = embeddingLikeRows(count: 600, dimensions: dimensions, unitNorm: false, seed: 0xED17)
    var index = SignCodeIndex(dimensions: dimensions)
    index.append(rows: rows.prefix(300).flatMap { $0 })
    index.append(rows: rows.dropFirst(300).flatMap { $0 })

    // The engine's swap-remove, then an overwrite.
    for row in [17, 0, 597, 250] {
        index.removeSwappingLast(row: row)
        rows[row] = rows[rows.count - 1]
        rows.removeLast()
    }
    let replacement = embeddingLikeRows(count: 1, dimensions: dimensions, unitNorm: false, seed: 0xED18)[0]
    index.replace(row: 42, with: replacement)
    rows[42] = replacement

    let fresh = SignCodeIndex(dimensions: dimensions, rows: rows.flatMap { $0 })
    #expect(index.count == fresh.count)
    for query in queries(near: rows, count: 8, seed: 0xED19) + [replacement] {
        #expect(Set(index.candidates(for: query, limit: 64)) == Set(fresh.candidates(for: query, limit: 64)))
    }
    #expect(index.candidates(for: replacement, limit: 1) == [42])
}

private struct SliceAgreement: Sendable {
    var limit = 0
    var singleCounts: [Int] = []
    var distinctCounts: [Int] = []
    /// Per probe: slice counts (0 = the default) whose shortlist differed from one slice.
    var mismatchedSlices: [[Int]] = []
    var found = 0
    var probeCount = 0
    var recall: Double { Double(found) / Double(probeCount * 10) }
}

@Test("Sign-code shortlist is the same over any number of parallel slices")
func signCodeShortlistAcrossSlices() async {
    let result = await offCooperativePool { () -> SliceAgreement in
        // Large enough that the default picks several slices.
        let dimensions = 128
        let rows = embeddingLikeRows(count: 52_000, dimensions: dimensions, unitNorm: true, seed: 0x511CE)
        let index = SignCodeIndex(dimensions: dimensions, rows: rows.flatMap { $0 })
        var result = SliceAgreement(limit: SignCodeIndex.candidateCount(topK: 10))
        let probes = queries(near: rows, count: 20, seed: 0x511CF)
        result.probeCount = probes.count
        for query in probes {
            let single = index.candidates(for: query, limit: result.limit, slices: 1)
            result.singleCounts.append(single.count)
            result.distinctCounts.append(Set(single).count)
            var mismatched = [2, 3, 7].filter { slices in
                Set(index.candidates(for: query, limit: result.limit, slices: slices)) != Set(single)
            }
            if Set(index.candidates(for: query, limit: result.limit)) != Set(single) { mismatched.append(0) }
            result.mismatchedSlices.append(mismatched)
            result.found += exactTopRows(rows, query: query, k: 10).filter(Set(single).contains).count
        }
        return result
    }
    #expect(result.singleCounts.allSatisfy { $0 == result.limit }, "\(result.singleCounts)")
    #expect(result.distinctCounts.allSatisfy { $0 == result.limit }, "shortlist rows are distinct")
    #expect(result.mismatchedSlices.allSatisfy { $0.isEmpty }, "\(result.mismatchedSlices)")
    // Denser than the 8k store, so the 256-row shortlist covers less of each neighborhood.
    #expect(result.recall >= 0.98, "shortlist recall@10 \(result.recall)")
}

@Test("Sign-code shortlist size grows with topK above its floor")
func signCodeCandidateCount() {
    #expect(SignCodeIndex.candidateCount(topK: 1) == SignCodeIndex.minCandidates)
    #expect(SignCodeIndex.candidateCount(topK: 10) == SignCodeIndex.minCandidates)
    #expect(SignCodeIndex.candidateCount(topK: 30) == 30 * SignCodeIndex.candidatesPerResult)
    #expect(SignCodeIndex.candidateCount(topK: Int.max) == Int.max)
}

// MARK: - MetalANNSVectorEngine quantized scan

#if canImport(Metal) && canImport(MetalANNS)
private func makeEngines(
    metric: VectorMetric,
    rows: [[Float]],
    dimensions: Int,
    quantizedScanMinVectorCount: Int
) async throws -> (engine: MetalANNSVectorEngine, exact: AccelerateVectorEngine, frameIds: [UInt64]) {
    // Non-monotonic ids so ordering can't fall out of insertion order.
    let frameIds = rows.indices.map { UInt64(($0 * 7 + 3) % (rows.count * 7 + 11)) + 100 }
    let engine = try MetalANNSVectorEngine(
        metric: metric,
        dimensions: dimensions,
        searchMode: .exact,
        quantizedScanMinVectorCount: quantizedScanMinVectorCount
    )
    let exact = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
    try await engine.addBatch(frameIds: frameIds, vectors: rows)
    try await exact.addBatch(frameIds: frameIds, vectors: rows)
    return (engine, exact, frameIds)
}

/// Hits are exact: every score is the exact score of its frame, order is best-first with
/// the frameId tie-break, and the set reaches `minRecall` of the exact top `topK`.
private func expectRescoredHits(
    _ engine: MetalANNSVectorEngine,
    _ exact: AccelerateVectorEngine,
    probes: [[Float]],
    topK: Int,
    minRecall: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    var found = 0
    for query in probes {
        let hits = try await engine.search(vector: query, topK: topK)
        let all = try await exact.search(vector: query, topK: 1_000_000)
        let exactScores = Dictionary(uniqueKeysWithValues: all.map { ($0.frameId, $0.score) })
        #expect(hits.count == topK, sourceLocation: sourceLocation)
        for hit in hits {
            let expected = try #require(exactScores[hit.frameId], sourceLocation: sourceLocation)
            #expect(abs(hit.score - expected) <= 1e-4 * max(1, abs(expected)), sourceLocation: sourceLocation)
        }
        for (lhs, rhs) in zip(hits, hits.dropFirst()) {
            #expect(
                lhs.score > rhs.score || (lhs.score == rhs.score && lhs.frameId < rhs.frameId),
                "hits must be best-first with frameId tie-break",
                sourceLocation: sourceLocation
            )
        }
        let truth = Set(all.prefix(topK).map(\.frameId))
        found += hits.filter { truth.contains($0.frameId) }.count
    }
    let recall = Double(found) / Double(probes.count * topK)
    #expect(recall >= minRecall, "recall@\(topK) \(recall)", sourceLocation: sourceLocation)
}

@Test(
    "MetalANNS quantized scan returns exact scores and order at the threshold",
    .enabled(if: MetalANNSVectorEngine.isAvailable),
    arguments: [VectorMetric.cosine, .dot]
)
func metalANNSQuantizedScanRescoresExactly(metric: VectorMetric) async throws {
    let dimensions = 128
    let rows = embeddingLikeRows(count: 6_000, dimensions: dimensions, unitNorm: metric == .cosine, seed: 0xA5)
    let (engine, exact, frameIds) = try await makeEngines(
        metric: metric, rows: rows, dimensions: dimensions, quantizedScanMinVectorCount: rows.count
    )
    let probes = queries(near: rows, count: 24, seed: 0xA6)
    try await expectRescoredHits(engine, exact, probes: probes, topK: 10, minRecall: 0.99)
    try await expectRescoredHits(engine, exact, probes: probes, topK: 30, minRecall: 0.98)
    #expect(await engine.quantizedScanCount == probes.count * 2)

    // Under cosine a stored vector is its own nearest neighbor.
    if metric == .cosine {
        let hits = try await engine.search(vector: rows[1_234], topK: 5)
        #expect(hits.first?.frameId == frameIds[1_234])
    }
}

@Test(
    "MetalANNS keeps the exact scan below the quantized-scan threshold",
    .enabled(if: MetalANNSVectorEngine.isAvailable)
)
func metalANNSExactScanBelowQuantizedThreshold() async throws {
    let dimensions = 128
    let rows = embeddingLikeRows(count: 2_000, dimensions: dimensions, unitNorm: true, seed: 0xB5)
    let (engine, exact, _) = try await makeEngines(
        metric: .cosine, rows: rows, dimensions: dimensions, quantizedScanMinVectorCount: rows.count + 1
    )
    for query in queries(near: rows, count: 6, seed: 0xB6) {
        let actual = try await engine.search(vector: query, topK: 10)
        let expected = try await exact.search(vector: query, topK: 10)
        #expect(actual.map(\.frameId) == expected.map(\.frameId))
    }
    #expect(await engine.quantizedScanCount == 0)
    #expect(MetalANNSVectorEngine.defaultQuantizedScanMinVectorCount == 50_000)
}

@Test(
    "MetalANNS keeps the exact scan for L2, narrow vectors, and large topK",
    .enabled(if: MetalANNSVectorEngine.isAvailable)
)
func metalANNSExactScanWhereSignCodesDoNotApply() async throws {
    let wide = embeddingLikeRows(count: 2_000, dimensions: 128, unitNorm: true, seed: 0xC5)
    let l2 = try await makeEngines(metric: .l2, rows: wide, dimensions: 128, quantizedScanMinVectorCount: 1)
    _ = try await l2.engine.search(vector: wide[3], topK: 10)
    #expect(await l2.engine.quantizedScanCount == 0)

    let narrow = embeddingLikeRows(count: 2_000, dimensions: 64, unitNorm: true, seed: 0xC6)
    let small = try await makeEngines(metric: .cosine, rows: narrow, dimensions: 64, quantizedScanMinVectorCount: 1)
    _ = try await small.engine.search(vector: narrow[3], topK: 10)
    #expect(await small.engine.quantizedScanCount == 0)

    // A shortlist over a quarter of the store saves little; scan it all exactly.
    let cosine = try await makeEngines(metric: .cosine, rows: wide, dimensions: 128, quantizedScanMinVectorCount: 1)
    let topK = wide.count / (4 * SignCodeIndex.candidatesPerResult) + 1
    let actual = try await cosine.engine.search(vector: wide[3], topK: topK)
    let expected = try await cosine.exact.search(vector: wide[3], topK: topK)
    #expect(actual.map(\.frameId) == expected.map(\.frameId))
    #expect(await cosine.engine.quantizedScanCount == 0)
}

@Test(
    "MetalANNS quantized scan follows adds, overwrites and removes",
    .enabled(if: MetalANNSVectorEngine.isAvailable)
)
func metalANNSQuantizedScanTracksMutations() async throws {
    let dimensions = 128
    let rows = embeddingLikeRows(count: 4_000, dimensions: dimensions, unitNorm: true, seed: 0xE5)
    let (engine, exact, frameIds) = try await makeEngines(
        metric: .cosine, rows: rows, dimensions: dimensions, quantizedScanMinVectorCount: 1_000
    )
    let probes = queries(near: rows, count: 8, seed: 0xE6)
    // First search encodes the store.
    try await expectRescoredHits(engine, exact, probes: probes, topK: 10, minRecall: 0.99)

    // Near-duplicates of stored rows, as re-ingested text would produce.
    let extra = queries(near: rows, count: 3, seed: 0xE7)
    // Remove (swap-remove moves the last row), overwrite, single add, batch add with overwrite.
    for frameId in [frameIds[0], frameIds[1_999], frameIds[3_999]] {
        try await engine.remove(frameId: frameId)
        try await exact.remove(frameId: frameId)
    }
    try await engine.add(frameId: frameIds[10], vector: extra[0])
    try await exact.add(frameId: frameIds[10], vector: extra[0])
    try await engine.add(frameId: 9_000_001, vector: extra[1])
    try await exact.add(frameId: 9_000_001, vector: extra[1])
    try await engine.addBatch(frameIds: [9_000_002, frameIds[20]], vectors: [extra[2], extra[1]])
    try await exact.addBatch(frameIds: [9_000_002, frameIds[20]], vectors: [extra[2], extra[1]])

    try await expectRescoredHits(engine, exact, probes: probes + extra, topK: 10, minRecall: 0.99)
    #expect(try await engine.search(vector: extra[0], topK: 1).first?.frameId == frameIds[10])
    #expect(try await engine.search(vector: extra[2], topK: 1).first?.frameId == 9_000_002)
    let removed = Set([frameIds[0], frameIds[1_999], frameIds[3_999]])
    for query in probes {
        let hits = try await engine.search(vector: query, topK: 30)
        #expect(hits.allSatisfy { !removed.contains($0.frameId) })
    }
}
#endif
