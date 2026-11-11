import Foundation
import Testing
import WaxCore
@testable import WaxVectorSearch

// A store whose vectors went through commits, replacements, removals, merges and a reopen must
// answer searches like an engine that saw the same changes in memory: the same frames in the
// same order. Scores may differ in the last bit: a reload holds the rows in a different order,
// and the batched dot products round by position. Above 50k vectors of at least 128 dimensions
// MetalANNS shortlists by sign code, so that path is covered too.

private let identityDimension = 128
private let identityFrameCount = 60_000

private struct IdentityRandom {
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

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24) * 2 - 1
    }

    mutating func vector() -> [Float] {
        (0..<identityDimension).map { _ in unit() }
    }

    mutating func frames(_ count: Int, below bound: Int) -> [UInt64] {
        var picked = Set<UInt64>()
        while picked.count < count {
            picked.insert(next() % UInt64(bound))
        }
        return picked.sorted()
    }
}

/// One commit's worth of changes, applied in this order: puts, then removals.
private struct IdentityStep {
    var puts: [(frameId: UInt64, vector: [Float])] = []
    var removals: [UInt64] = []
}

private func identitySteps(random: inout IdentityRandom) -> [IdentityStep] {
    var steps: [IdentityStep] = []
    // The first two commits write every frame's vector.
    for range in [0..<40_000, 40_000..<identityFrameCount] {
        steps.append(IdentityStep(puts: range.map { (UInt64($0), random.vector()) }))
    }
    // A tenth replaced or removed: under the fifth that merges every run.
    var step = IdentityStep()
    let touched = random.frames(6_000, below: identityFrameCount)
    step.puts = touched.prefix(4_000).map { ($0, random.vector()) }
    step.removals = Array(touched.suffix(2_000))
    steps.append(step)
    // Then enough replacements, including re-adds of removed frames, that every run merges.
    step = IdentityStep()
    step.puts = random.frames(12_000, below: identityFrameCount).map { ($0, random.vector()) }
    step.removals = random.frames(500, below: identityFrameCount).filter { frameId in
        !step.puts.contains { $0.frameId == frameId }
    }
    steps.append(step)
    // Small commits on top of the merged run.
    for _ in 0..<3 {
        step = IdentityStep()
        step.puts = random.frames(50, below: identityFrameCount).map { ($0, random.vector()) }
        steps.append(step)
    }
    return steps
}

private func apply(_ step: IdentityStep, to engine: any VectorSearchEngine) async throws {
    try await engine.addBatch(frameIds: step.puts.map(\.frameId), vectors: step.puts.map(\.vector))
    for frameId in step.removals {
        try await engine.remove(frameId: frameId)
    }
}

/// Builds the store through `steps` and returns its URL; `reference` sees the same changes.
private func buildStore(
    metric: VectorMetric,
    steps: [IdentityStep],
    references: [any VectorSearchEngine]
) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-vector-run-identity-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let wax = try await Wax.create(at: url)
    for start in stride(from: 0, to: identityFrameCount, by: 10_000) {
        let contents = (start..<min(start + 10_000, identityFrameCount)).map { Data("frame \($0)".utf8) }
        _ = try await wax.putBatch(contents, options: Array(repeating: FrameMetaSubset(), count: contents.count))
    }
    try await wax.setVectorIndexConfiguration(dimension: UInt32(identityDimension), similarity: metric.toVecSimilarity())
    for step in steps {
        for start in stride(from: 0, to: step.puts.count, by: 5_000) {
            let chunk = step.puts[start..<min(start + 5_000, step.puts.count)]
            try await wax.putEmbeddingBatch(frameIds: chunk.map(\.frameId), vectors: chunk.map(\.vector))
        }
        for frameId in step.removals {
            try await wax.removeEmbedding(frameId: frameId)
        }
        try await wax.commit()
        for reference in references {
            try await apply(step, to: reference)
        }
    }
    let manifest = try #require(await wax.committedVecIndexManifest())
    #expect(manifest.runs.count < steps.count, "the commits merged runs")
    try await wax.close()
    return url
}

private func expectSameHits(
    _ loaded: any VectorSearchEngine,
    _ reference: any VectorSearchEngine,
    queries: [[Float]]
) async throws {
    for query in queries {
        let got = try await loaded.search(vector: query, topK: 10)
        let want = try await reference.search(vector: query, topK: 10)
        #expect(got.map(\.frameId) == want.map(\.frameId))
        #expect(got.count == want.count)
        for (gotHit, wantHit) in zip(got, want) {
            #expect(abs(gotHit.score - wantHit.score) <= 1e-5 * max(1, abs(wantHit.score)))
        }
    }
}

/// Runs `body` with its nonisolated async code and default actors (`Wax`, the engines) on a
/// serial dispatch queue instead of the cooperative pool. Each step here writes or merges tens
/// of thousands of vectors inside one `Wax` call; on the pool that held a thread for seconds at a
/// time, so a parallel run on a 3-core CI runner starved every other test.
private func offCooperativePool(_ body: () async throws -> Void) async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else {
        try await body()
        return
    }
    try await withTaskExecutorPreference(SerialQueueTaskExecutor()) {
        try await body()
    }
}

@available(macOS 15.0, iOS 18.0, *)
private final class SerialQueueTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "com.wax.tests.vector-run-identity")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

@Test(arguments: [VectorMetric.cosine, VectorMetric.dot])
func searchesOverReloadedVectorRunsMatchAnInMemoryEngine(metric: VectorMetric) async throws {
    try await offCooperativePool {
        try await searchReloadedVectorRuns(metric: metric)
    }
}

private func searchReloadedVectorRuns(metric: VectorMetric) async throws {
    var random = IdentityRandom(seed: metric == .cosine ? 11 : 12)
    let steps = identitySteps(random: &random)
    let queries = (0..<40).map { _ in random.vector() }

    let accelerateReference = try AccelerateVectorEngine(metric: metric, dimensions: identityDimension)
    var references: [any VectorSearchEngine] = [accelerateReference]
    #if canImport(Metal) && canImport(MetalANNS)
    let metalReference = MetalANNSVectorEngine.isAvailable
        ? try MetalANNSVectorEngine(metric: metric, dimensions: identityDimension)
        : nil
    if let metalReference { references.append(metalReference) }
    #endif

    let url = try await buildStore(metric: metric, steps: steps, references: references)
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.open(at: url)
    let accelerate = try await AccelerateVectorEngine.load(from: wax, metric: metric, dimensions: identityDimension)
    try await expectSameHits(accelerate, accelerateReference, queries: queries)
    #if canImport(Metal) && canImport(MetalANNS)
    if let metalReference {
        let metal = try await MetalANNSVectorEngine.load(from: wax, metric: metric, dimensions: identityDimension)
        try await expectSameHits(metal, metalReference, queries: queries)
        #expect(await metal.quantizedScanCount > 0, "the sign-code shortlist answered the searches")
        #expect(await metalReference.quantizedScanCount > 0)
    }
    #endif
    try await wax.close()
}
