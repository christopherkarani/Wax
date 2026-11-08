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
    // Explicit types: the inferred form exceeds the Linux type-checker budget.
    let modulus = count * 7 + 11
    let frameIds: [UInt64] = (0..<count).map { (index: Int) -> UInt64 in
        UInt64((index * 7 + 3) % modulus) + 100
    }
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

/// Puts frames `0...max(frameIds)` into a new store, so every id in `frameIds` names a frame.
private func putFrames(_ wax: Wax, covering frameIds: [UInt64]) async throws {
    let count = Int((frameIds.max() ?? 0) + 1)
    _ = try await wax.putBatch(
        Array(repeating: Data("v".utf8), count: count),
        options: Array(repeating: FrameMetaSubset(), count: count)
    )
}

/// Writes `vectors` for `frameIds` to a new store's WAL and commits them as its vector index.
private func commitVectors(
    _ wax: Wax,
    frameIds: [UInt64],
    vectors: [[Float]],
    metric: VectorMetric,
    dimensions: Int
) async throws {
    try await putFrames(wax, covering: frameIds)
    try await wax.putEmbeddingBatch(frameIds: frameIds, vectors: vectors)
    try await wax.setVectorIndexConfiguration(dimension: UInt32(dimensions), similarity: metric.toVecSimilarity())
    try await wax.commit()
}

// MARK: - MetalANNS returns similarity, best-first (finding 1)

#if canImport(Metal) && canImport(MetalANNS)
private func metalANNSAvailable() -> Bool {
    MetalANNSVectorEngine.isAvailable
}

/// In `.exact` mode MetalANNS scans flat up to `exactSearchMaxVectorCount` vectors, and the
/// engine then builds no graph. A cap of 0 sends every search to the graph, so tests of the
/// graph lifecycle (build, install, mutate, rebuild) still run it at small sizes.
private func makeGraphBackedMetalANNS(metric: VectorMetric, dimensions: Int) throws -> MetalANNSVectorEngine {
    try MetalANNSVectorEngine(metric: metric, dimensions: dimensions, searchMode: .exact, exactSearchMaxVectorCount: 0)
}

@Test(
    "MetalANNS engine matches Accelerate ordering and scores",
    .enabled(if: metalANNSAvailable()),
    // 1 and 10 are below the MetalANNS graph-degree minimum (exact fallback); 64 uses the index.
    arguments: [VectorMetric.cosine, .dot, .l2], [1, 10, 64]
)
func metalANNSMatchesAccelerateOrderingAndScores(metric: VectorMetric, count: Int) async throws {
    let dimensions = 16
    let dataset = makeDataset(count: count, dimensions: dimensions, seed: 0xC0FFEE)
    let accelerate = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
    let metalANNS = try makeGraphBackedMetalANNS(metric: metric, dimensions: dimensions)
    try await accelerate.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)
    try await metalANNS.addBatch(frameIds: dataset.frameIds, vectors: dataset.vectors)

    // Query is one of the stored vectors, so the nearest neighbor is unambiguous.
    let queryIndex = count / 2
    let query = dataset.vectors[queryIndex]
    let expected = try await accelerate.search(vector: query, topK: dataset.frameIds.count)

    // Pass 1 scans exactly while the graph build is pending; pass 2 uses the graph (64).
    for _ in 0..<2 {
        let actual = try await metalANNS.search(vector: query, topK: dataset.frameIds.count)

        #expect(actual.count == expected.count)
        #expect(actual.first?.frameId == dataset.frameIds[queryIndex])
        #expect(actual.map(\.frameId) == expected.map(\.frameId))
        let tolerance: Float = metric == .cosine ? 1e-4 : 1e-3
        for (lhs, rhs) in zip(actual, expected) {
            #expect(abs(lhs.score - rhs.score) <= tolerance, "\(metric) score mismatch for frame \(lhs.frameId): \(lhs.score) vs \(rhs.score)")
        }
        expectSortedBestFirst(actual)

        let timed = try await metalANNS.searchTimed(vector: query, topK: 5)
        #expect(timed.hits.map(\.frameId) == Array(expected.prefix(5)).map(\.frameId))
        expectSortedBestFirst(timed.hits)
        await metalANNS.waitForPendingGraphBuild()
    }
    if count > 32 {
        #expect(await metalANNS.isGraphReady)
    } else {
        #expect(!(await metalANNS.isGraphReady))
    }
}

@Test(
    "LoadedVectorSearchEngine under gpuOnly ranks nearest neighbor first",
    .enabled(if: metalANNSAvailable()),
    // MetalANNS graph construction needs more nodes than its degree (32); smaller stores
    // must still work under gpuOnly.
    arguments: [1, 10, 64]
)
func loadedVectorSearchEngineGpuOnlyRanksNearestFirst(count: Int) async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dimensions = 8
    let dataset = makeDataset(count: count, dimensions: dimensions, seed: 42)
    let wax = try await Wax.create(at: tempDir.appendingPathComponent("gpu-only.wax"))
    try await commitVectors(
        wax,
        frameIds: dataset.frameIds,
        vectors: dataset.vectors,
        metric: .cosine,
        dimensions: dimensions
    )

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

    let queryIndex = count / 2
    let query = dataset.vectors[queryIndex]
    let gpuHits = try await gpu.search(vector: query, topK: 10)
    let cpuHits = try await cpu.search(vector: query, topK: 10)

    #expect(gpuHits.count == min(10, count))
    let top = try #require(gpuHits.first)
    #expect(top.frameId == dataset.frameIds[queryIndex])
    #expect(abs(top.score - 1.0) < 1e-4)
    #expect(gpuHits.map(\.frameId) == cpuHits.map(\.frameId))
    expectSortedBestFirst(gpuHits)

    try await wax.close()
}
#endif

#if canImport(Metal) && canImport(MetalANNS)
private func expectMetalANNSParity(
    _ metalANNS: MetalANNSVectorEngine,
    _ accelerate: AccelerateVectorEngine,
    query: [Float],
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    // First search may scan exactly while a graph build is pending; the second, after
    // the build settles, goes through the graph when the store is large enough for one.
    for _ in 0..<2 {
        let actual = try await metalANNS.search(vector: query, topK: count)
        let expected = try await accelerate.search(vector: query, topK: count)
        #expect(actual.map(\.frameId) == expected.map(\.frameId), sourceLocation: sourceLocation)
        for (lhs, rhs) in zip(actual, expected) {
            #expect(abs(lhs.score - rhs.score) <= 1e-4, sourceLocation: sourceLocation)
        }
        await metalANNS.waitForPendingGraphBuild()
    }
}

@Test(
    "MetalANNS engine handles overwrite and re-add after the graph is built",
    .enabled(if: metalANNSAvailable())
)
func metalANNSHandlesMutationsAfterGraphBuild() async throws {
    let dimensions = 8
    // 40 > MetalANNS graph degree (32), so the graph exists before the mutations.
    let base = makeDataset(count: 40, dimensions: dimensions, seed: 0xBEEF)
    let extra = makeDataset(count: 60, dimensions: dimensions, seed: 0xFEED)
    let metalANNS = try makeGraphBackedMetalANNS(metric: .cosine, dimensions: dimensions)
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    func apply(_ body: (any VectorSearchEngine) async throws -> Void) async throws {
        try await body(metalANNS)
        try await body(accelerate)
    }

    try await apply { try await $0.addBatch(frameIds: base.frameIds, vectors: base.vectors) }
    let query = base.vectors[3]
    try await expectMetalANNSParity(metalANNS, accelerate, query: query, count: 40)

    // Overwrite an existing id via add.
    try await apply { try await $0.add(frameId: base.frameIds[3], vector: extra.vectors[0]) }
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[0], count: 40)

    // Overwrite existing ids via addBatch.
    try await apply {
        try await $0.addBatch(frameIds: [base.frameIds[4], base.frameIds[5]], vectors: [extra.vectors[1], extra.vectors[2]])
    }
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[1], count: 40)

    // Remove, then re-add the same id.
    try await apply { try await $0.remove(frameId: base.frameIds[6]) }
    try await expectMetalANNSParity(metalANNS, accelerate, query: query, count: 39)
    try await apply { try await $0.add(frameId: base.frameIds[6], vector: extra.vectors[3]) }
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[3], count: 40)
}

@Test(
    "MetalANNS engine re-adds a removed id without dropping the graph",
    .enabled(if: metalANNSAvailable())
)
func metalANNSReAddsRemovedIdInPlace() async throws {
    let dimensions = 8
    let base = makeDataset(count: 40, dimensions: dimensions, seed: 0xBEEF)
    let extra = makeDataset(count: 1, dimensions: dimensions, seed: 0xFEED)
    let metalANNS = try makeGraphBackedMetalANNS(metric: .cosine, dimensions: dimensions)
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    _ = try await metalANNS.search(vector: base.vectors[0], topK: 5)
    await metalANNS.waitForPendingGraphBuild()
    #expect(await metalANNS.isGraphReady)

    let reused = base.frameIds[6]
    for engine in [metalANNS, accelerate] as [any VectorSearchEngine] {
        try await engine.remove(frameId: reused)
        try await engine.add(frameId: reused, vector: extra.vectors[0])
    }
    // MetalANNS 0.4.0 re-inserts a soft-deleted id into its slot, so no rebuild is needed.
    #expect(await metalANNS.isGraphReady)
    let hits = try await metalANNS.search(vector: extra.vectors[0], topK: 1)
    #expect(hits.first?.frameId == reused)
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[0], count: 40)
}

@Test(
    "MetalANNS engine grows past the capacity its graph was built with",
    .enabled(if: metalANNSAvailable())
)
func metalANNSGrowsPastBuiltCapacity() async throws {
    let dimensions = 8
    let base = makeDataset(count: 40, dimensions: dimensions, seed: 0xBEEF)
    let extra = makeDataset(count: 60, dimensions: dimensions, seed: 0xFEED)
    let metalANNS = try makeGraphBackedMetalANNS(metric: .cosine, dimensions: dimensions)
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await expectMetalANNSParity(metalANNS, accelerate, query: base.vectors[3], count: 40)

    // The graph is built with capacity 2x its node count; insert one at a time past that.
    for index in 0..<60 {
        let frameId = 10_000 + UInt64(index)
        try await metalANNS.add(frameId: frameId, vector: extra.vectors[index])
        try await accelerate.add(frameId: frameId, vector: extra.vectors[index])
    }
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[30], count: 100)
}

@Test(
    "MetalANNS add and remove racing a graph rebuild are not lost",
    .enabled(if: metalANNSAvailable())
)
func metalANNSMutationsRacingGraphRebuildAreNotLost() async throws {
    let dimensions = 16
    let base = makeDataset(count: 100, dimensions: dimensions, seed: 0x5EED)
    let extra = makeDataset(count: 2, dimensions: dimensions, seed: 0xD00D)
    let newId: UInt64 = 1_000_000
    let removedId = base.frameIds[7]

    for _ in 0..<5 {
        let metalANNS = try makeGraphBackedMetalANNS(metric: .cosine, dimensions: dimensions)
        let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
        try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
        try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)
        _ = try await metalANNS.search(vector: base.vectors[1], topK: 10)

        // Overwriting drops the graph; the next search rebuilds it while add/remove run.
        try await metalANNS.add(frameId: base.frameIds[0], vector: extra.vectors[0])
        try await accelerate.add(frameId: base.frameIds[0], vector: extra.vectors[0])
        async let raced = metalANNS.search(vector: base.vectors[1], topK: 10)
        async let added: Void = metalANNS.add(frameId: newId, vector: extra.vectors[1])
        async let removed: Void = metalANNS.remove(frameId: removedId)
        _ = try await (raced, added, removed)
        try await accelerate.add(frameId: newId, vector: extra.vectors[1])
        try await accelerate.remove(frameId: removedId)

        // Check both the search right after the race and the graph built once it settles.
        for _ in 0..<2 {
            let nearNew = try await metalANNS.search(vector: extra.vectors[1], topK: 10)
            #expect(nearNew.first?.frameId == newId)
            let all = try await metalANNS.search(vector: base.vectors[7], topK: 100)
            #expect(!all.contains { $0.frameId == removedId })
            try await expectMetalANNSParity(metalANNS, accelerate, query: base.vectors[7], count: 100)
        }
        #expect(await metalANNS.isGraphReady)
    }
}

/// Holds MetalANNS graph builds until released, and counts how many started.
private actor GraphBuildGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0

    func enter() async {
        started += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private struct InjectedGraphBuildFailure: Error {}

@Test(
    "MetalANNS search during an in-flight graph build returns exact results",
    .enabled(if: metalANNSAvailable())
)
func metalANNSSearchDuringPendingGraphBuildIsExact() async throws {
    let dimensions = 16
    let base = makeDataset(count: 100, dimensions: dimensions, seed: 0xA11CE)
    let extra = makeDataset(count: 1, dimensions: dimensions, seed: 0xB0B)
    let gate = GraphBuildGate()
    let metalANNS = try MetalANNSVectorEngine(
        metric: .cosine,
        dimensions: dimensions,
        searchMode: .exact,
        exactSearchMaxVectorCount: 0,
        graphBuildHook: { await gate.enter() }
    )
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)

    // The first search schedules a build; the gate holds it, so these scan exactly.
    for query in base.vectors.prefix(3) {
        try await expectExactParity(metalANNS, accelerate, query: query, count: 100)
    }
    #expect(!(await metalANNS.isGraphReady))

    // Remove while the build is held: its snapshot is now stale.
    let newId: UInt64 = 1_000_000
    let removedId = base.frameIds[7]
    for engine in [metalANNS, accelerate] as [any VectorSearchEngine] {
        try await engine.add(frameId: newId, vector: extra.vectors[0])
        try await engine.remove(frameId: removedId)
    }
    try await expectExactParity(metalANNS, accelerate, query: extra.vectors[0], count: 100)

    await gate.release()
    await metalANNS.waitForPendingGraphBuild()
    // Single flight: one build ran, and its stale graph was discarded.
    #expect(await gate.started == 1)
    #expect(!(await metalANNS.isGraphReady))

    // Debounce: after a discard, a search that saw a mutation since the last check does not
    // start another build; the next search with no mutation in between does.
    let removedAgainId = base.frameIds[8]
    try await metalANNS.remove(frameId: removedAgainId)
    try await accelerate.remove(frameId: removedAgainId)
    try await expectExactParity(metalANNS, accelerate, query: extra.vectors[0], count: 100)
    await metalANNS.waitForPendingGraphBuild()
    #expect(await gate.started == 1)

    // The next search schedules a fresh build from current data.
    try await expectExactParity(metalANNS, accelerate, query: extra.vectors[0], count: 100)
    await metalANNS.waitForPendingGraphBuild()
    #expect(await gate.started == 2)
    #expect(await metalANNS.isGraphReady)
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[0], count: 100)
    let all = try await metalANNS.search(vector: base.vectors[7], topK: 100)
    #expect(!all.contains { $0.frameId == removedId })
    #expect(all.contains { $0.frameId == newId })
}

@Test(
    "MetalANNS installs a graph built before concurrent appends and catches them up",
    .enabled(if: metalANNSAvailable())
)
func metalANNSAppendsDuringGraphBuildAreCaughtUp() async throws {
    let dimensions = 16
    let base = makeDataset(count: 100, dimensions: dimensions, seed: 0xA99E)
    let extra = makeDataset(count: 20, dimensions: dimensions, seed: 0xA99F)
    let gate = GraphBuildGate()
    let metalANNS = try MetalANNSVectorEngine(
        metric: .cosine,
        dimensions: dimensions,
        searchMode: .exact,
        exactSearchMaxVectorCount: 0,
        graphBuildHook: { await gate.enter() }
    )
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await expectExactParity(metalANNS, accelerate, query: base.vectors[0], count: 100)

    // Only appends while the build is held, through add and addBatch.
    let singleIds = (0..<5).map { 1_000_000 + UInt64($0) }
    let batchIds = (5..<20).map { 1_000_000 + UInt64($0) }
    for engine in [metalANNS, accelerate] as [any VectorSearchEngine] {
        for (offset, frameId) in singleIds.enumerated() {
            try await engine.add(frameId: frameId, vector: extra.vectors[offset])
        }
        try await engine.addBatch(frameIds: batchIds, vectors: Array(extra.vectors[5..<20]))
    }
    try await expectExactParity(metalANNS, accelerate, query: extra.vectors[3], count: 120)

    await gate.release()
    await metalANNS.waitForPendingGraphBuild()
    // The appends-only build is installed and caught up, without a second build.
    #expect(await metalANNS.isGraphReady)
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[3], count: 120)
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[17], count: 120)
    try await expectMetalANNSParity(metalANNS, accelerate, query: base.vectors[50], count: 120)
    #expect(await gate.started == 1)
}

@Test(
    "MetalANNS append-only ingest after a discarded build still installs a graph",
    .enabled(if: metalANNSAvailable())
)
func metalANNSAppendOnlyIngestAfterDiscardedBuildInstallsGraph() async throws {
    let dimensions = 16
    let base = makeDataset(count: 100, dimensions: dimensions, seed: 0xDEB0)
    let extra = makeDataset(count: 20, dimensions: dimensions, seed: 0xDEB1)
    let gate = GraphBuildGate()
    let metalANNS = try MetalANNSVectorEngine(
        metric: .cosine,
        dimensions: dimensions,
        searchMode: .exact,
        exactSearchMaxVectorCount: 0,
        graphBuildHook: { await gate.enter() }
    )
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await expectExactParity(metalANNS, accelerate, query: base.vectors[0], count: 100)

    // One non-append mutation during the held build: that build is discarded.
    try await metalANNS.remove(frameId: base.frameIds[7])
    try await accelerate.remove(frameId: base.frameIds[7])
    await gate.release()
    await metalANNS.waitForPendingGraphBuild()
    #expect(!(await metalANNS.isGraphReady))

    // Steady append-only ingest with a search after each append.
    for (offset, vector) in extra.vectors.enumerated() {
        let frameId = 1_000_000 + UInt64(offset)
        try await metalANNS.add(frameId: frameId, vector: vector)
        try await accelerate.add(frameId: frameId, vector: vector)
        _ = try await metalANNS.search(vector: vector, topK: 10)
    }
    await metalANNS.waitForPendingGraphBuild()
    #expect(await gate.started == 2)
    #expect(await metalANNS.isGraphReady)
    try await expectMetalANNSParity(metalANNS, accelerate, query: extra.vectors[19], count: 119)
}

@Test(
    "MetalANNS load in a cancelled task does not record a build failure",
    .enabled(if: metalANNSAvailable())
)
func metalANNSCancelledLoadDoesNotBlockGraphBuild() async throws {
    let dimensions = 16
    let base = makeDataset(count: 100, dimensions: dimensions, seed: 0xCA4C)
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let wax = try await Wax.create(at: tempDir.appendingPathComponent("cancelled-load.wax"))
    // Committed vectors are stored as written; the engine normalizes cosine rows on load.
    try await commitVectors(
        wax,
        frameIds: base.frameIds,
        vectors: base.vectors,
        metric: .cosine,
        dimensions: dimensions
    )

    let engine = try await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await MetalANNSVectorEngine.load(
            from: wax,
            metric: .cosine,
            dimensions: dimensions,
            exactSearchMaxVectorCount: 0
        )
    }.value
    // Cancellation is not a build failure: no count, and the next search may build.
    #expect(await engine.graphBuildFailureCount == 0)
    #expect(!(await engine.isGraphReady))
    let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await expectMetalANNSParity(engine, accelerate, query: base.vectors[5], count: 100)
    #expect(await engine.isGraphReady)
    try await wax.close()
}

@Test(
    "MetalANNS falls back to exact search when the graph build fails",
    .enabled(if: metalANNSAvailable())
)
func metalANNSFailedGraphBuildFallsBackToExactSearch() async throws {
    let dimensions = 16
    let base = makeDataset(count: 100, dimensions: dimensions, seed: 0xFA11)
    let extra = makeDataset(count: 1, dimensions: dimensions, seed: 0xFA12)
    let gate = GraphBuildGate()
    await gate.release()
    let metalANNS = try MetalANNSVectorEngine(
        metric: .l2,
        dimensions: dimensions,
        searchMode: .exact,
        exactSearchMaxVectorCount: 0,
        graphBuildHook: {
            await gate.enter()
            throw InjectedGraphBuildFailure()
        }
    )
    let accelerate = try AccelerateVectorEngine(metric: .l2, dimensions: dimensions)
    try await metalANNS.addBatch(frameIds: base.frameIds, vectors: base.vectors)
    try await accelerate.addBatch(frameIds: base.frameIds, vectors: base.vectors)

    try await expectExactParity(metalANNS, accelerate, query: base.vectors[3], count: 100)
    await metalANNS.waitForPendingGraphBuild()
    #expect(await metalANNS.graphBuildFailureCount == 1)
    #expect(!(await metalANNS.isGraphReady))

    // Backed off: further searches stay exact and do not retry the build.
    for query in base.vectors.prefix(5) {
        try await expectExactParity(metalANNS, accelerate, query: query, count: 100)
        await metalANNS.waitForPendingGraphBuild()
    }
    #expect(await gate.started == 1)
    let timed = try await metalANNS.searchTimed(vector: base.vectors[4], topK: 5)
    let expected = try await accelerate.search(vector: base.vectors[4], topK: 5)
    #expect(timed.hits.map(\.frameId) == expected.map(\.frameId))

    // A mutation allows one retry.
    try await metalANNS.add(frameId: 1_000_000, vector: extra.vectors[0])
    try await accelerate.add(frameId: 1_000_000, vector: extra.vectors[0])
    try await expectExactParity(metalANNS, accelerate, query: extra.vectors[0], count: 101)
    await metalANNS.waitForPendingGraphBuild()
    #expect(await gate.started == 2)
    #expect(await metalANNS.graphBuildFailureCount == 2)
}

@Test(
    "MetalANNS exact mode at or below the exact-scan cap never builds the graph",
    .enabled(if: metalANNSAvailable())
)
func metalANNSExactModeOpenSkipsGraphBuild() async throws {
    // The auto-selection threshold: stores this large open on the MetalANNS engine.
    let count = MetalANNSVectorEngine.autoThreshold
    let dimensions = 8
    let base = makeDataset(count: count, dimensions: dimensions, seed: 0x0FE7)
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let wax = try await Wax.create(at: tempDir.appendingPathComponent("exact-open.wax"))
    // Dense ids: every committed vector needs a frame, and the ids do not matter here.
    let frameIds = (0..<count).map { UInt64($0) }
    try await commitVectors(
        wax,
        frameIds: frameIds,
        vectors: base.vectors,
        metric: .cosine,
        dimensions: dimensions
    )
    let seed = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
    try await seed.addBatch(frameIds: frameIds, vectors: base.vectors)

    let engine = try await MetalANNSVectorEngine.load(from: wax, metric: .cosine, dimensions: dimensions)
    // MetalANNS answers exact searches at this size with a flat scan, so open builds no graph.
    #expect(!(await engine.isGraphReady))

    let extra = makeDataset(count: 1, dimensions: dimensions, seed: 0x0FE8)
    try await engine.add(frameId: 5_000_000, vector: extra.vectors[0])
    try await seed.add(frameId: 5_000_000, vector: extra.vectors[0])
    for query in [base.vectors[17], base.vectors[count - 1], extra.vectors[0]] {
        let actual = try await engine.search(vector: query, topK: 10)
        let expected = try await seed.search(vector: query, topK: 10)
        #expect(actual.map(\.frameId) == expected.map(\.frameId))
        for (lhs, rhs) in zip(actual, expected) {
            #expect(abs(lhs.score - rhs.score) <= 1e-4)
        }
        // Searches do not schedule a background build either.
        await engine.waitForPendingGraphBuild()
        #expect(!(await engine.isGraphReady))
    }
    try await wax.close()
}

/// Exact-path parity: the store has no current graph, so results must equal Accelerate's.
private func expectExactParity(
    _ metalANNS: MetalANNSVectorEngine,
    _ accelerate: AccelerateVectorEngine,
    query: [Float],
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    #expect(!(await metalANNS.isGraphReady), sourceLocation: sourceLocation)
    let actual = try await metalANNS.search(vector: query, topK: count)
    let expected = try await accelerate.search(vector: query, topK: count)
    #expect(actual.map(\.frameId) == expected.map(\.frameId), sourceLocation: sourceLocation)
    for (lhs, rhs) in zip(actual, expected) {
        #expect(abs(lhs.score - rhs.score) <= 1e-4 * max(1, abs(rhs.score)), sourceLocation: sourceLocation)
    }
}
#endif

// MARK: - Metal cosine kernels with partial threadgroups (finding 2)

#if canImport(Metal)
@Test(
    "MetalVectorEngine matches CPU cosine for partial threadgroups",
    .enabled(if: metalDeviceAvailable()),
    // 3 and 13 are not multiples of 4 (unaligned rows, 12/52-byte threadgroup memory).
    arguments: [3, 13, 128, 384], [1, 5, 95, 257]
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

/// Builds a flat segment whose second row (frameId 2) contains NaN, as stores written before
/// inserts validated finiteness can.
private func segmentWithNaNRow() throws -> Data {
    try VectorSerializer.serializeFlatVectors(
        [1.0, 0.0, .nan, 1.0, 0.0, 1.0],
        frameIds: [1, 2, 3],
        metric: .cosine,
        dimensions: 2
    )
}

/// Commits, as a store's vector index, rows whose second (frameId 2) contains NaN, as stores
/// written before inserts validated finiteness can hold. Inserts reject NaN, so the rows go
/// in as a vector import.
private func commitVectorsWithNaNRow(_ wax: Wax) async throws {
    try await putFrames(wax, covering: [1, 2, 3])
    try await wax.stageVectorImportForNextCommit(CommittedVectors(
        dimension: 2,
        similarity: .cosine,
        frameIds: [1, 2, 3],
        vectors: [1.0, 0.0, .nan, 1.0, 0.0, 1.0]
    ))
    try await wax.commit()
}

/// Expects `wax`'s committed vectors to leave out the NaN row of ``commitVectorsWithNaNRow(_:)``.
private func expectNaNRowDropped(_ wax: Wax, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let committed = try #require(try await wax.readCommittedVectors(), sourceLocation: sourceLocation)
    #expect(committed.droppedNonFiniteRowCount == 1, sourceLocation: sourceLocation)
    #expect(Set(committed.frameIds) == [1, 3], sourceLocation: sourceLocation)
    #expect(committed.vectors.allSatisfy { $0.isFinite }, sourceLocation: sourceLocation)
}

@Test func vectorSerializerDropsNonFiniteRowsAndReportsCount() throws {
    let decoded = try VectorSerializer.decodeVecSegment(from: try segmentWithNaNRow())
    guard case .metal(let info, let vectors, let frameIds) = decoded else {
        Issue.record("unexpected payload")
        return
    }
    #expect(info.droppedNonFiniteRowCount == 1)
    #expect(info.vectorCount == 2)
    #expect(frameIds == [1, 3])
    #expect(vectors == [1.0, 0.0, 0.0, 1.0])
}

@Test func accelerateEngineLoadsCommittedVectorsWithNonFiniteRowAndKeepsItOut() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let url = tempDir.appendingPathComponent("nan-row.wax")
    let wax = try await Wax.create(at: url)
    try await commitVectorsWithNaNRow(wax)
    try await expectNaNRowDropped(wax)

    // The manifest counts the rows as written; the engine loads only the finite ones.
    #expect(await wax.committedVecIndexManifest()?.vectorCount == 3)
    #expect(try await LoadedVectorSearchEngine.projectedVectorCount(for: wax, fallbackDimensions: 2) == 3)
    let engine = try await AccelerateVectorEngine.load(from: wax, metric: .cosine, dimensions: 2)
    #expect(await engine.droppedNonFiniteRowCount == 1)

    let hits = try await engine.search(vector: [0.0, 1.0], topK: 10)
    #expect(hits.map(\.frameId) == [3, 1])
    #expect(hits.allSatisfy { $0.score.isFinite })

    // Staging and committing again never brings the NaN row back, before or after reopen.
    try await engine.stageForCommit(into: wax)
    try await wax.commit()
    try await expectNaNRowDropped(wax)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    try await expectNaNRowDropped(reopened)
    let reloaded = try await AccelerateVectorEngine.load(from: reopened, metric: .cosine, dimensions: 2)
    let reloadedHits = try await reloaded.search(vector: [0.0, 1.0], topK: 10)
    #expect(reloadedHits.map(\.frameId) == [3, 1])
    #expect(reloadedHits.allSatisfy { $0.score.isFinite })
    try await reopened.close()
}

#if canImport(Metal) && canImport(MetalANNS)
@Test(
    "MetalANNS engine loads a segment with a non-finite row",
    .enabled(if: metalANNSAvailable())
)
func metalANNSEngineLoadsSegmentWithNonFiniteRow() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let url = tempDir.appendingPathComponent("nan-row-ann.wax")
    let wax = try await Wax.create(at: url)
    try await commitVectorsWithNaNRow(wax)

    let engine = try await LoadedVectorSearchEngine.load(
        from: wax,
        metric: .cosine,
        dimensions: 2,
        preference: .gpuOnly
    )
    guard case .metalANNS(let metalANNS) = engine else {
        Issue.record("expected MetalANNS engine")
        return
    }
    #expect(await metalANNS.droppedNonFiniteRowCount == 1)
    let hits = try await engine.search(vector: [0.0, 1.0], topK: 10)
    #expect(hits.map(\.frameId) == [3, 1])

    // Staging and committing again never brings the NaN row back, before or after reopen.
    try await metalANNS.stageForCommit(into: wax)
    try await wax.commit()
    try await expectNaNRowDropped(wax)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    try await expectNaNRowDropped(reopened)
    try await reopened.close()
}
#endif

// MARK: - Non-finite distances rank last (review item 2)

@Test(arguments: [VectorMetric.cosine, .dot, .l2])
func nonFiniteDistanceScoresBelowEveryFiniteScore(metric: VectorMetric) {
    let worstFinite = metric.score(fromDistance: 1e30)
    for distance in [Float.nan, .infinity, -.infinity] {
        let score = metric.score(fromDistance: distance)
        #expect(score == -.infinity, "\(metric) distance \(distance) -> \(score)")
        #expect(score < worstFinite)
    }
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
