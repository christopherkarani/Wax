import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import Wax
import WaxCore
@testable import WaxVectorSearch

// MARK: - Shared helpers

private struct SplitMix64 {
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

private func makeDataset(count: Int, dimensions: Int, seed: UInt64) -> (frameIds: [UInt64], vectors: [[Float]]) {
    var rng = SplitMix64(seed: seed)
    var vectors: [[Float]] = []
    vectors.reserveCapacity(count)
    for _ in 0..<count {
        vectors.append((0..<dimensions).map { _ in rng.nextUnitFloat() })
    }
    // Non-monotonic ids so ordering can't accidentally fall out of insertion order.
    let frameIds = (0..<count).map { UInt64(($0 * 7 + 3) % (count * 7 + 11)) + 100 }
    return (frameIds, vectors)
}

private func expectSortedBestFirst(_ hits: [(frameId: UInt64, score: Float)], sourceLocation: SourceLocation = #_sourceLocation) {
    for (lhs, rhs) in zip(hits, hits.dropFirst()) {
        #expect(lhs.score >= rhs.score, "hits must be sorted best-first", sourceLocation: sourceLocation)
    }
}

private func metalDeviceAvailable() -> Bool {
    #if canImport(Metal)
    return MTLCreateSystemDefaultDevice() != nil
    #else
    return false
    #endif
}

private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - MetalANNS returns similarity, best-first (finding 1)

#if canImport(Metal) && canImport(MetalANNS)
private func metalANNSAvailable() -> Bool {
    MetalANNSVectorEngine.isAvailable
}

@Test(
    "MetalANNS engine matches Accelerate ordering and scores",
    .enabled(if: metalANNSAvailable()),
    arguments: [VectorMetric.cosine, .dot, .l2]
)
func metalANNSMatchesAccelerateOrderingAndScores(metric: VectorMetric) async throws {
    let dimensions = 16
    let dataset = makeDataset(count: 64, dimensions: dimensions, seed: 0xC0FFEE)
    let accelerate = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
    let metalANNS = try MetalANNSVectorEngine(metric: metric, dimensions: dimensions)
    try await accelerate.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)
    try await metalANNS.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)

    // Query is one of the stored vectors, so the nearest neighbor is unambiguous.
    let query = dataset.vectors[17]
    let expected = try await accelerate.search(vector: query, topK: dataset.frameIds.count)
    let actual = try await metalANNS.search(vector: query, topK: dataset.frameIds.count)

    #expect(actual.count == expected.count)
    #expect(actual.first?.frameId == dataset.frameIds[17])
    #expect(actual.map(\.frameId) == expected.map(\.frameId))
    let tolerance: Float = metric == .cosine ? 1e-4 : 1e-3
    for (lhs, rhs) in zip(actual, expected) {
        #expect(abs(lhs.score - rhs.score) <= tolerance, "\(metric) score mismatch for frame \(lhs.frameId): \(lhs.score) vs \(rhs.score)")
    }
    expectSortedBestFirst(actual)

    let timed = try await metalANNS.searchTimed(vector: query, topK: 5)
    #expect(timed.hits.map(\.frameId) == Array(expected.prefix(5)).map(\.frameId))
    expectSortedBestFirst(timed.hits)
}

@Test(
    "LoadedVectorSearchEngine under gpuOnly ranks nearest neighbor first",
    .enabled(if: metalANNSAvailable())
)
func loadedVectorSearchEngineGpuOnlyRanksNearestFirst() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dimensions = 8
    // MetalANNS graph construction needs more nodes than its default degree (32).
    let dataset = makeDataset(count: 64, dimensions: dimensions, seed: 42)
    let wax = try await Wax.create(at: tempDir.appendingPathComponent("gpu-only.wax"))
    let seed = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await seed.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)
    try await seed.stageForCommit(into: wax)

    let gpu = try await LoadedVectorSearchEngine.load(
        from: wax,
        metric: .cosine,
        dimensions: dimensions,
        preference: .gpuOnly
    )
    let cpu = try await LoadedVectorSearchEngine.load(
        from: wax,
        metric: .cosine,
        dimensions: dimensions,
        preference: .cpuOnly
    )
    #expect(gpu.kind == .metalANNS)
    #expect(cpu.kind == .accelerate)

    let query = dataset.vectors[5]
    let gpuHits = try await gpu.search(vector: query, topK: 10)
    let cpuHits = try await cpu.search(vector: query, topK: 10)

    let top = try #require(gpuHits.first)
    #expect(top.frameId == dataset.frameIds[5])
    #expect(abs(top.score - 1.0) < 1e-4)
    #expect(gpuHits.map(\.frameId) == cpuHits.map(\.frameId))
    expectSortedBestFirst(gpuHits)

    try await wax.close()
}
#endif

// MARK: - Metal cosine kernels with partial threadgroups (finding 2)

#if canImport(Metal)
@Test(
    "MetalVectorEngine matches CPU cosine for partial threadgroups",
    .enabled(if: metalDeviceAvailable()),
    arguments: [128, 384], [1, 5, 95, 257]
)
func metalVectorEngineMatchesCPUForPartialThreadgroups(dimensions: Int, count: Int) async throws {
    let dataset = makeDataset(count: count, dimensions: dimensions, seed: UInt64(dimensions * 1_000 + count))
    let metal = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
    let cpu = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await metal.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)
    try await cpu.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)

    let queryIndex = count / 2
    let query = dataset.vectors[queryIndex]
    let metalHits = try await metal.search(vector: query, topK: count)
    let cpuHits = try await cpu.search(vector: query, topK: count)

    #expect(metalHits.count == count)
    #expect(metalHits.first?.frameId == dataset.frameIds[queryIndex])
    let cpuScores = Dictionary(uniqueKeysWithValues: cpuHits.map { ($0.frameId, $0.score) })
    for hit in metalHits {
        let expected = try #require(cpuScores[hit.frameId])
        #expect(abs(hit.score - expected) <= 1e-4, "frame \(hit.frameId): metal \(hit.score) vs cpu \(expected)")
    }
    expectSortedBestFirst(metalHits)
}

@Test("MetalVectorEngine shaders keep every thread in the cooperative load and barrier")
func metalCosineKernelsDoNotReturnBeforeBarrier() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/Shaders/CosineDistance.metal"),
        encoding: .utf8
    )
    for kernel in ["cosineDistanceKernelOptimized", "cosineDistanceKernelSIMD4", "cosineDistanceKernelSIMD8"] {
        let start = try #require(source.range(of: "kernel void \(kernel)("))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\nkernel void ")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        let barrier = try #require(body.range(of: "threadgroup_barrier"))
        #expect(!body[..<barrier.lowerBound].contains("return;"), "\(kernel) returns before threadgroup_barrier")
    }
}

// MARK: - Transient buffer pool stays bounded (finding 3)

@Test(
    "MetalVectorEngine transient buffer pool stays bounded when add and search alternate",
    .enabled(if: metalDeviceAvailable())
)
func metalVectorEngineTransientPoolStaysBounded() async throws {
    let dimensions = 4
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
    let dataset = makeDataset(count: 600, dimensions: dimensions, seed: 7)
    for (frameId, vector) in zip(dataset.frameIds, dataset.vectors) {
        try await engine.add(frameId: frameId, vector: vector)
        _ = try await engine.search(vector: vector, topK: 1)
    }

    let stats = await engine.debugBufferPoolStats()
    // Geometric growth: 64 -> 128 -> 256 -> 512 -> 1024 is four allocations.
    #expect(stats.transientAllocations <= 5, "allocations: \(stats.transientAllocations)")
    #expect(stats.pooledBufferSets <= MetalVectorEngine.maxPooledTransientBufferSets)
    #expect(stats.pooledBufferSets >= 1)
}
#endif

// MARK: - VectorSerializer slices, alignment, non-finite payloads (finding 4)

@Test func vectorSerializerDecodesDataSliceWithNonZeroStartIndex() throws {
    let vectors: [Float] = [0.25, -0.5, 1.0, 2.0, 3.5, -4.0]
    let frameIds: [UInt64] = [9, 3]
    let blob = try VectorSerializer.serializeFlatVectors(vectors, frameIds: frameIds, metric: .l2, dimensions: 3)

    // Odd prefix length shifts every field off natural alignment as well.
    let padded = Data([0xAA, 0xBB, 0xCC]) + blob
    let slice = padded.dropFirst(3)
    #expect(slice.startIndex == 3)

    let decoded = try VectorSerializer.decodeVecSegment(from: slice)
    guard case .metal(let info, let decodedVectors, let decodedFrameIds) = decoded else {
        Issue.record("unexpected payload")
        return
    }
    #expect(info.dimension == 3)
    #expect(info.vectorCount == 2)
    #expect(info.similarity == .l2)
    #expect(decodedVectors == vectors)
    #expect(decodedFrameIds == frameIds)
    #expect(try VectorSerializer.detectEncoding(from: slice) == .flat)
}

@Test func vectorSerializerRejectsNonFiniteVectorPayload() throws {
    let blob = try VectorSerializer.serializeFlatVectors(
        [1.0, 0.0, 0.0, 1.0],
        frameIds: [1, 2],
        metric: .cosine,
        dimensions: 2
    )
    // Overwrite the third float (vector 1, dim 0) with NaN.
    var corrupted = blob
    let nanBits = Float.nan.bitPattern.littleEndian
    withUnsafeBytes(of: nanBits) { bytes in
        corrupted.replaceSubrange((36 + 8)..<(36 + 12), with: bytes)
    }

    do {
        _ = try VectorSerializer.decodeVecSegment(from: corrupted)
        Issue.record("Expected non-finite vector payload to be rejected")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Expected invalidToc, got \(error)")
            return
        }
        #expect(reason.contains("non-finite"))
    }
}

@Test func vectorSerializerAvoidsAlignedTypedBinding() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSerializer.swift"),
        encoding: .utf8
    )
    #expect(!source.contains("bindMemory(to:"))
}

// MARK: - Accelerate bounded top-k keeps deterministic ordering (finding 6)

@Test func accelerateTopKMatchesFullSortWithTieBreak() async throws {
    let dimensions = 3
    let engine = try AccelerateVectorEngine(metric: .dot, dimensions: dimensions)
    // Few distinct vectors, many ids: lots of exact score ties.
    let distinct: [[Float]] = [[1, 0, 0], [0, 1, 0], [0.5, 0.5, 0], [0, 0, 1], [1, 1, 0]]
    var frameIds: [UInt64] = []
    var vectors: [[Float]] = []
    for index in 0..<200 {
        frameIds.append(UInt64((index * 37) % 211))
        vectors.append(distinct[index % distinct.count])
    }
    try await engine.addBatch(frameIds: frameIds, vectors: vectors)

    let query: [Float] = [1, 0.25, 0]
    func dot(_ vector: [Float]) -> Float { zip(vector, query).reduce(0) { $0 + $1.0 * $1.1 } }
    let reference = zip(frameIds, vectors)
        .map { (frameId: $0.0, score: dot($0.1)) }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.frameId < rhs.frameId }
            return lhs.score > rhs.score
        }

    for topK in [1, 7, 40, 200, 500] {
        let hits = try await engine.search(vector: query, topK: topK)
        let expected = Array(reference.prefix(topK))
        #expect(hits.map(\.frameId) == expected.map(\.frameId), "topK \(topK)")
        #expect(hits.map(\.score) == expected.map(\.score), "topK \(topK)")
    }
}
