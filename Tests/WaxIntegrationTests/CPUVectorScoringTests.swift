import Foundation
import Testing
import WaxCore
@testable import WaxVectorSearch

// The CPU scoring kernels (WaxVectorSearchC/wax_vector_scores.c) that AccelerateVectorEngine
// uses where Accelerate is unavailable. They sum in a different order than a sequential loop
// and may use FMA, so scores are compared against a double-precision reference within the
// worst-case rounding bound of a Float dot product in any summation order:
//
//   |fl(x . y) - x . y| <= gamma(n) * sum |x_i * y_i|,  gamma(n) = n u / (1 - n u),  u = 2^-24.
//
// The bound holds for recursive, pairwise and blocked summation alike, with or without
// fused multiply-adds, so it is the tolerance for every kernel and for the Swift scalar
// loop they replace. Anything outside it is a bug, not rounding.

// MARK: - Fixtures

private struct KernelRandom {
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

    mutating func floats(_ count: Int) -> [Float] {
        (0..<count).map { (_: Int) -> Float in nextUnitFloat() }
    }
}

private let unitRoundoff = 0x1p-24

private func gamma(_ n: Int) -> Double {
    let nu = Double(n) * unitRoundoff
    return nu / (1 - nu)
}

/// Exact-enough dot product and the sum of |products| that scales its rounding bound.
private func referenceDot(_ row: ArraySlice<Float>, _ query: [Float]) -> (dot: Double, magnitude: Double) {
    var dot = 0.0
    var magnitude = 0.0
    for (value, q) in zip(row, query) {
        let product = Double(value) * Double(q)
        dot += product
        magnitude += abs(product)
    }
    return (dot, magnitude)
}

/// The loop AccelerateVectorEngine ran where Accelerate is unavailable.
private func scalarDot(_ row: ArraySlice<Float>, _ query: [Float]) -> Float {
    var dot: Float = 0
    for (value, q) in zip(row, query) {
        dot += value * q
    }
    return dot
}

private func squaredNorm(_ values: ArraySlice<Float>) -> Float {
    var total: Float = 0
    for value in values {
        total += value * value
    }
    return total
}

private let testDimensions = [1, 3, 7, 8, 15, 16, 17, 383, 384, 385]

/// Every kernel this CPU can run, plus automatic dispatch.
private let testKernels: [CPUVectorScoring.Kernel?] = [nil] + CPUVectorScoring.availableKernels

private func kernelName(_ kernel: CPUVectorScoring.Kernel?) -> String {
    kernel.map { "\($0)" } ?? "automatic"
}

/// Scores `rows` (row-major) with `kernel` through buffers offset `floatOffset` floats from an
/// allocation, so callers can check unaligned rows, query and scores.
private func kernelScores(
    rows: [Float],
    rowCount: Int,
    dimensions: Int,
    query: [Float],
    squaredNorms: [Float]? = nil,
    queryNorm: Float = 0,
    kernel: CPUVectorScoring.Kernel?,
    floatOffset: Int = 0
) -> [Float] {
    let rowStorage = UnsafeMutablePointer<Float>.allocate(capacity: rows.count + floatOffset + 1)
    let queryStorage = UnsafeMutablePointer<Float>.allocate(capacity: query.count + floatOffset + 1)
    let scoreStorage = UnsafeMutablePointer<Float>.allocate(capacity: rowCount + floatOffset + 1)
    defer {
        rowStorage.deallocate()
        queryStorage.deallocate()
        scoreStorage.deallocate()
    }
    let rowBase = rowStorage + floatOffset
    let queryBase = queryStorage + floatOffset
    let scoreBase = scoreStorage + floatOffset
    rowBase.initialize(from: rows, count: rows.count)
    queryBase.initialize(from: query, count: query.count)
    // A sentinel after the last score catches writes past the end.
    scoreBase.initialize(repeating: .nan, count: rowCount + 1)
    scoreBase[rowCount] = 12_345
    if let squaredNorms {
        squaredNorms.withUnsafeBufferPointer { (norms: UnsafeBufferPointer<Float>) -> Void in
            CPUVectorScoring.score(
                rows: UnsafePointer(rowBase),
                rowCount: rowCount,
                dimensions: dimensions,
                query: UnsafePointer(queryBase),
                squaredNorms: norms.baseAddress,
                queryNorm: queryNorm,
                into: scoreBase,
                kernel: kernel
            )
        }
    } else {
        CPUVectorScoring.score(
            rows: UnsafePointer(rowBase),
            rowCount: rowCount,
            dimensions: dimensions,
            query: UnsafePointer(queryBase),
            squaredNorms: nil,
            queryNorm: 0,
            into: scoreBase,
            kernel: kernel
        )
    }
    #expect(scoreBase[rowCount] == 12_345, "kernel wrote past the last score")
    return Array(UnsafeBufferPointer(start: scoreBase, count: rowCount))
}

// MARK: - Dot products against a double-precision reference

@Test(
    "CPU dot kernels stay within the Float rounding bound of a double reference",
    arguments: testDimensions
)
func cpuDotKernelsMatchDoubleReference(dimensions: Int) {
    // 13 rows: three 4-row blocks and a remainder row.
    let rowCount = 13
    var random = KernelRandom(seed: UInt64(0xD07 + dimensions))
    let rows = random.floats(rowCount * dimensions)
    let query = random.floats(dimensions)
    for kernel in testKernels {
        let scores = kernelScores(rows: rows, rowCount: rowCount, dimensions: dimensions, query: query, kernel: kernel)
        for row in 0..<rowCount {
            let slice = rows[(row * dimensions)..<((row + 1) * dimensions)]
            let reference = referenceDot(slice, query)
            let bound = gamma(dimensions) * reference.magnitude
            let error = abs(Double(scores[row]) - reference.dot)
            #expect(
                error <= bound,
                "\(kernelName(kernel)) dim \(dimensions) row \(row): \(scores[row]) vs \(reference.dot), error \(error) > \(bound)"
            )
            // The scalar loop the kernels replace obeys the same bound, so the two agree
            // within twice of it.
            let scalar = scalarDot(slice, query)
            #expect(Double(abs(scores[row] - scalar)) <= 2 * bound, "\(kernelName(kernel)) dim \(dimensions) row \(row)")
        }
    }
}

@Test("CPU dot kernels are exact where every partial sum is representable", arguments: testDimensions)
func cpuDotKernelsAreExactOnSmallIntegers(dimensions: Int) {
    // Products and partial sums of small integers are exact in Float in any order, so every
    // kernel, with or without FMA, must give the exact integer.
    let rowCount = 6
    var random = KernelRandom(seed: UInt64(dimensions))
    let rows = (0..<(rowCount * dimensions)).map { (_: Int) -> Float in Float(Int(random.next() % 17) - 8) }
    let query = (0..<dimensions).map { (_: Int) -> Float in Float(Int(random.next() % 9) - 4) }
    for kernel in testKernels {
        let scores = kernelScores(rows: rows, rowCount: rowCount, dimensions: dimensions, query: query, kernel: kernel)
        for row in 0..<rowCount {
            let slice = rows[(row * dimensions)..<((row + 1) * dimensions)]
            #expect(Double(scores[row]) == referenceDot(slice, query).dot, "\(kernelName(kernel)) dim \(dimensions) row \(row)")
        }
    }
}

// MARK: - L2 scores

@Test("CPU L2 kernels apply the engine's -(norm + queryNorm - 2 dot) exactly", arguments: testDimensions)
func cpuL2KernelsMatchEngineFormula(dimensions: Int) {
    let rowCount = 9
    var random = KernelRandom(seed: UInt64(0x12 + dimensions))
    let rows = random.floats(rowCount * dimensions)
    let query = random.floats(dimensions)
    let norms = (0..<rowCount).map { (row: Int) -> Float in
        squaredNorm(rows[(row * dimensions)..<((row + 1) * dimensions)])
    }
    let queryNorm = squaredNorm(query[...])
    for kernel in testKernels {
        let dots = kernelScores(rows: rows, rowCount: rowCount, dimensions: dimensions, query: query, kernel: kernel)
        let scores = kernelScores(
            rows: rows,
            rowCount: rowCount,
            dimensions: dimensions,
            query: query,
            squaredNorms: norms,
            queryNorm: queryNorm,
            kernel: kernel
        )
        for row in 0..<rowCount {
            // Bit for bit the Swift expression AccelerateVectorEngine applies to each dot product.
            let expected: Float = -(norms[row] + queryNorm - (2 * dots[row]))
            #expect(scores[row].bitPattern == expected.bitPattern, "\(kernelName(kernel)) dim \(dimensions) row \(row)")

            // And close to the true negative squared distance: the dot product's bound
            // (doubled), the norms' own bounds, and the rounding of the final two steps.
            let slice = rows[(row * dimensions)..<((row + 1) * dimensions)]
            let reference = referenceDot(slice, query)
            var distance = 0.0
            for (value, q) in zip(slice, query) {
                distance += (Double(value) - Double(q)) * (Double(value) - Double(q))
            }
            let normMagnitude = Double(norms[row]) + Double(queryNorm)
            let bound = gamma(dimensions) * (2 * reference.magnitude + normMagnitude)
                + 3 * unitRoundoff * (normMagnitude + 2 * reference.magnitude)
            #expect(
                abs(Double(scores[row]) + distance) <= bound,
                "\(kernelName(kernel)) dim \(dimensions) row \(row): \(scores[row]) vs \(-distance)"
            )
        }
    }
}

// MARK: - Layout independence

@Test("CPU kernels give the same bits for unaligned buffers", arguments: [7, 16, 383, 384, 385])
func cpuKernelsIgnoreBufferAlignment(dimensions: Int) {
    let rowCount = 11
    var random = KernelRandom(seed: UInt64(0xA11 + dimensions))
    let rows = random.floats(rowCount * dimensions)
    let query = random.floats(dimensions)
    let norms = random.floats(rowCount).map { (value: Float) -> Float in abs(value) + 1 }
    for kernel in testKernels {
        let aligned = kernelScores(rows: rows, rowCount: rowCount, dimensions: dimensions, query: query, kernel: kernel)
        let alignedL2 = kernelScores(
            rows: rows, rowCount: rowCount, dimensions: dimensions, query: query,
            squaredNorms: norms, queryNorm: 1.5, kernel: kernel
        )
        for offset in 1...7 {
            let shifted = kernelScores(
                rows: rows, rowCount: rowCount, dimensions: dimensions, query: query,
                kernel: kernel, floatOffset: offset
            )
            let shiftedL2 = kernelScores(
                rows: rows, rowCount: rowCount, dimensions: dimensions, query: query,
                squaredNorms: norms, queryNorm: 1.5, kernel: kernel, floatOffset: offset
            )
            #expect(shifted.map(\.bitPattern) == aligned.map(\.bitPattern), "\(kernelName(kernel)) offset \(offset)")
            #expect(shiftedL2.map(\.bitPattern) == alignedL2.map(\.bitPattern), "\(kernelName(kernel)) offset \(offset)")
        }
    }
}

@Test("A row scores the same bits wherever it sits in the store", arguments: [3, 17, 384])
func cpuKernelsScoreEachRowIndependently(dimensions: Int) {
    // Identical rows at every position of a 4-row block and in the remainder must tie
    // exactly, or the frameId tie-break would depend on where rows were stored.
    var random = KernelRandom(seed: UInt64(0x51D + dimensions))
    let row = random.floats(dimensions)
    let query = random.floats(dimensions)
    let rowCount = 11
    let rows = Array([[Float]](repeating: row, count: rowCount).joined())
    for kernel in testKernels {
        let scores = kernelScores(rows: rows, rowCount: rowCount, dimensions: dimensions, query: query, kernel: kernel)
        #expect(Set(scores.map(\.bitPattern)).count == 1, "\(kernelName(kernel)): \(scores)")
        let single = kernelScores(rows: row, rowCount: 1, dimensions: dimensions, query: query, kernel: kernel)
        #expect(single[0].bitPattern == scores[0].bitPattern, "\(kernelName(kernel))")
    }
}

// MARK: - Zero, NaN and infinity

@Test("CPU kernels score zero vectors as exactly zero", arguments: testDimensions)
func cpuKernelsScoreZeroVectors(dimensions: Int) {
    var random = KernelRandom(seed: UInt64(dimensions))
    let query = random.floats(dimensions)
    let zeroRows = [Float](repeating: 0, count: 5 * dimensions)
    let mixedRows = random.floats(5 * dimensions)
    let zeroQuery = [Float](repeating: 0, count: dimensions)
    for kernel in testKernels {
        let zeroRowScores = kernelScores(rows: zeroRows, rowCount: 5, dimensions: dimensions, query: query, kernel: kernel)
        #expect(zeroRowScores.allSatisfy { (score: Float) -> Bool in score == 0 }, "\(kernelName(kernel)): \(zeroRowScores)")
        let zeroQueryScores = kernelScores(rows: mixedRows, rowCount: 5, dimensions: dimensions, query: zeroQuery, kernel: kernel)
        #expect(zeroQueryScores.allSatisfy { (score: Float) -> Bool in score == 0 }, "\(kernelName(kernel)): \(zeroQueryScores)")
        let l2 = kernelScores(
            rows: zeroRows, rowCount: 5, dimensions: dimensions, query: zeroQuery,
            squaredNorms: [Float](repeating: 0, count: 5), queryNorm: 0, kernel: kernel
        )
        #expect(l2.allSatisfy { (score: Float) -> Bool in score == 0 }, "\(kernelName(kernel)): \(l2)")
    }
}

@Test("CPU kernels propagate NaN and infinity like the scalar loop", arguments: [1, 7, 16, 17, 384])
func cpuKernelsPropagateNonFiniteValues(dimensions: Int) {
    // The engine rejects non-finite vectors, but finite ones can overflow. When the products
    // themselves are non-finite the sum is the same in every order (NaN if any product is
    // NaN or both infinities occur, else the infinity), so kernels must match the scalar loop.
    var random = KernelRandom(seed: UInt64(0x1AF + dimensions))
    let query = random.floats(dimensions).map { (value: Float) -> Float in value == 0 ? 0.5 : value }
    let last = dimensions - 1
    var cases: [[Float]] = []
    var nanRow = random.floats(dimensions)
    nanRow[last] = .nan
    cases.append(nanRow)
    var plusInfinity = random.floats(dimensions)
    plusInfinity[last] = query[last] > 0 ? .infinity : -.infinity
    cases.append(plusInfinity)
    var minusInfinity = random.floats(dimensions)
    minusInfinity[0] = query[0] > 0 ? -.infinity : .infinity
    cases.append(minusInfinity)
    if dimensions > 1 {
        var both = random.floats(dimensions)
        both[0] = query[0] > 0 ? .infinity : -.infinity
        both[last] = query[last] > 0 ? -.infinity : .infinity
        cases.append(both)
    }
    var zeroTimesInfinity = random.floats(dimensions)
    var zeroQuery = query
    zeroQuery[last] = 0
    zeroTimesInfinity[last] = .infinity
    let rows = Array(cases.joined())
    for kernel in testKernels {
        let scores = kernelScores(rows: rows, rowCount: cases.count, dimensions: dimensions, query: query, kernel: kernel)
        for (index, row) in cases.enumerated() {
            let scalar = scalarDot(row[...], query)
            if scalar.isNaN {
                #expect(scores[index].isNaN, "\(kernelName(kernel)) case \(index): \(scores[index])")
            } else {
                #expect(scores[index] == scalar, "\(kernelName(kernel)) case \(index): \(scores[index]) vs \(scalar)")
            }
        }
        let zeroTimesInfinityScore = kernelScores(
            rows: zeroTimesInfinity, rowCount: 1, dimensions: dimensions, query: zeroQuery, kernel: kernel
        )
        #expect(zeroTimesInfinityScore[0].isNaN, "\(kernelName(kernel)): 0 * inf must be NaN")

        // Finite rows whose products overflow: one product past Float.max is +/-infinity in
        // any order, as is a store of such rows with both signs of query.
        let doubled = [Float](repeating: 2, count: dimensions)
        var overflowRows = [Float](repeating: 0, count: 2 * dimensions)
        overflowRows[last] = .greatestFiniteMagnitude
        overflowRows[dimensions + last] = -.greatestFiniteMagnitude
        let overflowScores = kernelScores(rows: overflowRows, rowCount: 2, dimensions: dimensions, query: doubled, kernel: kernel)
        #expect(overflowScores == [.infinity, -.infinity], "\(kernelName(kernel)): \(overflowScores)")
    }
}

// MARK: - Dispatch

@Test func cpuVectorScoringReportsItsKernels() {
    #expect(CPUVectorScoring.availableKernels.first == .generic)
    #expect(CPUVectorScoring.availableKernels.contains(CPUVectorScoring.automaticKernel))
    #if arch(x86_64)
    // AVX2+FMA is chosen whenever the CPU has it.
    #expect(CPUVectorScoring.automaticKernel == CPUVectorScoring.availableKernels.last)
    #else
    #expect(CPUVectorScoring.availableKernels == [.generic])
    #endif
}

// MARK: - AccelerateVectorEngine search parity (Accelerate on Apple, the kernels elsewhere)

private func unitRows(_ random: inout KernelRandom, count: Int, dimensions: Int) -> [[Float]] {
    (0..<count).map { (_: Int) -> [Float] in
        let row = random.floats(dimensions)
        let norm = row.reduce(Float.zero) { (total: Float, value: Float) -> Float in total + value * value }.squareRoot()
        return row.map { (value: Float) -> Float in value / norm }
    }
}

/// The engine's score in double precision and its Float rounding bound.
private func referenceScore(_ row: [Float], _ query: [Float], metric: VectorMetric) -> (score: Double, bound: Double) {
    let dot = referenceDot(row[...], query)
    let n = row.count
    switch metric {
    case .cosine, .dot:
        return (dot.dot, gamma(n) * dot.magnitude)
    case .l2:
        var distance = 0.0
        for (value, q) in zip(row, query) {
            distance += (Double(value) - Double(q)) * (Double(value) - Double(q))
        }
        let norms = Double(squaredNorm(row[...])) + Double(squaredNorm(query[...]))
        let bound = gamma(n) * (2 * dot.magnitude + norms) + 3 * unitRoundoff * (norms + 2 * dot.magnitude)
        return (-distance, bound)
    }
}

@Test(
    "AccelerateVectorEngine ranks like a double-precision reference for every metric",
    arguments: [VectorMetric.cosine, .dot, .l2], [7, 384, 385]
)
func accelerateEngineSearchMatchesReference(metric: VectorMetric, dimensions: Int) async throws {
    // 301 rows: not a multiple of the kernels' 4-row block.
    let count = 301
    var random = KernelRandom(seed: UInt64(0xE461 + dimensions))
    let rows = unitRows(&random, count: count, dimensions: dimensions)
    let frameIds: [UInt64] = (0..<count).map { (index: Int) -> UInt64 in UInt64((index * 37) % 1_009) + 5 }
    let engine = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
    try await engine.addBatch(frameIds: frameIds, vectors: rows)

    for probe in 0..<3 {
        let query = unitRows(&random, count: 1, dimensions: dimensions)[0]
        let reference = zip(frameIds, rows).map { (pair: (UInt64, [Float])) -> (frameId: UInt64, score: Double, bound: Double) in
            let scored = referenceScore(pair.1, query, metric: metric)
            return (pair.0, scored.score, scored.bound)
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.frameId < rhs.frameId : lhs.score > rhs.score }
        let byId = Dictionary(uniqueKeysWithValues: reference.map { (entry: (frameId: UInt64, score: Double, bound: Double)) -> (UInt64, (score: Double, bound: Double)) in
            (entry.frameId, (entry.score, entry.bound))
        })

        for topK in [1, 10, 100, count] {
            let hits = try await engine.search(vector: query, topK: topK)
            #expect(hits.count == topK)
            for hit in hits {
                let expected = try #require(byId[hit.frameId])
                #expect(abs(Double(hit.score) - expected.score) <= expected.bound, "\(metric) frame \(hit.frameId)")
            }
            // Ranks may differ from the reference only between scores closer than their
            // rounding bounds; everywhere else the order and the top-k set are the reference's.
            for (index, hit) in hits.enumerated() {
                let expected = reference[index]
                if hit.frameId != expected.frameId {
                    let actual = try #require(byId[hit.frameId])
                    #expect(
                        abs(actual.score - expected.score) <= actual.bound + expected.bound,
                        "\(metric) dim \(dimensions) probe \(probe) topK \(topK) rank \(index): \(hit.frameId) vs \(expected.frameId)"
                    )
                }
            }
        }
    }
}

@Test("AccelerateVectorEngine ties identical rows exactly, ordered by frameId", arguments: [VectorMetric.cosine, .dot, .l2])
func accelerateEngineTiesIdenticalRows(metric: VectorMetric) async throws {
    let dimensions = 384
    var random = KernelRandom(seed: 0x71E5)
    let distinct = unitRows(&random, count: 5, dimensions: dimensions)
    var frameIds: [UInt64] = []
    var rows: [[Float]] = []
    // Copies of each row land at every offset within the kernels' 4-row blocks.
    for index in 0..<203 {
        frameIds.append(UInt64((index * 53) % 401))
        rows.append(distinct[index % distinct.count])
    }
    let engine = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
    try await engine.addBatch(frameIds: frameIds, vectors: rows)
    let query = unitRows(&random, count: 1, dimensions: dimensions)[0]
    let hits = try await engine.search(vector: query, topK: rows.count)
    #expect(hits.count == rows.count)
    #expect(Set(hits.map(\.score)).count == distinct.count, "copies of one row must score the same bits")
    for (lhs, rhs) in zip(hits, hits.dropFirst()) {
        #expect(lhs.score > rhs.score || (lhs.score == rhs.score && lhs.frameId < rhs.frameId), "\(lhs) before \(rhs)")
    }
}

// MARK: - Parallel scoring

@Test("Parallel CPU scoring gives the same bits for any number of chunks", arguments: [VectorMetric.dot, .l2])
func cpuParallelScoringIsIndependentOfChunkCount(metric: VectorMetric) async {
    let dimensions = 385
    let rowCount = 1_003
    var random = KernelRandom(seed: 0xC4C)
    let rows = random.floats(rowCount * dimensions)
    let query = random.floats(dimensions)
    let norms: [Float]? = metric == .l2
        ? (0..<rowCount).map { (row: Int) -> Float in squaredNorm(rows[(row * dimensions)..<((row + 1) * dimensions)]) }
        : nil
    let queryNorm = squaredNorm(query[...])
    // concurrentPerform blocks its caller, so the scoring runs on a GCD thread.
    let results = await BlockingWork.run { () -> [[UInt32]] in
        [1, 2, 3, 4, 7, 16, rowCount, rowCount + 5].map { (chunks: Int) -> [UInt32] in
            CPUVectorScoring.scores(
                rows: rows,
                rowCount: rowCount,
                dimensions: dimensions,
                query: query,
                squaredNorms: norms,
                queryNorm: queryNorm,
                chunks: chunks
            ).map(\.bitPattern)
        }
    }
    let serial = kernelScores(
        rows: rows, rowCount: rowCount, dimensions: dimensions, query: query,
        squaredNorms: norms, queryNorm: queryNorm, kernel: nil
    ).map(\.bitPattern)
    for (index, result) in results.enumerated() {
        #expect(result == serial, "chunking \(index) differs from one serial call")
    }
}

@Test func cpuParallelChunkCountKeepsSmallStoresOnOneThread() {
    let minimum = CPUVectorScoring.minimumParallelChunkElements
    // Below two chunks' worth of work the scan stays on the calling thread.
    #expect(CPUVectorScoring.parallelChunkCount(rowCount: 1, dimensions: 384, processors: 8) == 1)
    #expect(CPUVectorScoring.parallelChunkCount(rowCount: (2 * minimum - 1) / 384, dimensions: 384, processors: 8) == 1)
    #expect(CPUVectorScoring.parallelChunkCount(rowCount: 2 * minimum / 384 + 1, dimensions: 384, processors: 8) == 2)
    // Never more chunks than processors, and never more than one on one processor.
    #expect(CPUVectorScoring.parallelChunkCount(rowCount: 1_000_000, dimensions: 384, processors: 4) == 4)
    #expect(CPUVectorScoring.parallelChunkCount(rowCount: 1_000_000, dimensions: 384, processors: 1) == 1)
    #expect(CPUVectorScoring.parallelChunkCount(rowCount: Int.max, dimensions: 384, processors: 6) == 6)
}

#if !canImport(Accelerate)
@Test("AccelerateVectorEngine's parallel kernel scan matches one serial scan", arguments: [VectorMetric.cosine, .dot, .l2])
func accelerateEngineParallelScanMatchesSerialScan(metric: VectorMetric) async throws {
    let dimensions = 384
    // Enough rows for several chunks.
    let count = 4 * CPUVectorScoring.minimumParallelChunkElements / dimensions + 3
    var random = KernelRandom(seed: 0x9A2)
    let rows = unitRows(&random, count: count, dimensions: dimensions)
    let frameIds: [UInt64] = (0..<count).map { (index: Int) -> UInt64 in UInt64((index * 7_919) % 100_003) }
    let engine = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
    try await engine.addBatch(frameIds: frameIds, vectors: rows)
    let flat = Array(rows.joined())
    let norms: [Float]? = metric == .l2 ? rows.map { (row: [Float]) -> Float in squaredNorm(row[...]) } : nil

    for _ in 0..<3 {
        let query = unitRows(&random, count: 1, dimensions: dimensions)[0]
        let serial = kernelScores(
            rows: flat, rowCount: count, dimensions: dimensions, query: query,
            squaredNorms: norms, queryNorm: squaredNorm(query[...]), kernel: nil
        )
        for topK in [10, 100] {
            let expected = VectorTopK.select(frameIds: frameIds, scores: serial, limit: topK)
            let hits = try await engine.search(vector: query, topK: topK)
            #expect(hits.map(\.frameId) == expected.map(\.frameId), "\(metric) topK \(topK)")
            #expect(hits.map(\.score.bitPattern) == expected.map(\.score.bitPattern), "\(metric) topK \(topK)")
        }
    }
}
#endif
