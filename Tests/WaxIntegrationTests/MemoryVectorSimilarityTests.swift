import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import Wax
import WaxTestSupport

// "bulky" is far from the query by angle but has a large norm; "aligned" points straight
// at the query with norm 1. Inner product ranks bulky first (10 > 1); cosine ranks aligned
// first (1 > 0.707).
private let bulkyText = "bulky note about magnets"
private let alignedText = "aligned note about compasses"
private let probeQuery = "probe"

private func keyedVector(for text: String) -> [Float] {
    if text.contains("bulky") { return [10, 10, 0, 0] }
    if text.contains("aligned") || text.contains(probeQuery) { return [1, 0, 0, 0] }
    return [0, 0, 0, 1]
}

/// Declares its similarity explicitly. Identity does not change with `similarity`, so a
/// reopen with the other metric passes the identity binding and reaches the metric check.
private struct KeyedEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize: Bool
    let similarity: VectorSimilarity

    init(similarity: VectorSimilarity, normalize: Bool = false) {
        self.similarity = similarity
        self.normalize = normalize
    }

    var identity: EmbeddingIdentity? {
        EmbeddingIdentity(provider: "Test", model: "Keyed", dimensions: dimensions, normalized: normalize)
    }

    func embed(_ text: String) async throws -> [Float] {
        keyedVector(for: text)
    }
}

/// Does not declare `similarity`, so it gets the protocol default.
private struct UndeclaredSimilarityEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize = false

    var identity: EmbeddingIdentity? {
        EmbeddingIdentity(provider: "Test", model: "Keyed", dimensions: dimensions, normalized: normalize)
    }

    func embed(_ text: String) async throws -> [Float] {
        keyedVector(for: text)
    }
}

private func memoryConfig(_ embedder: any EmbeddingProvider) -> Memory.Config {
    Memory.Config(requireOnDeviceProviders: false, embedding: .custom(embedder))
}

private func seed(_ url: URL, with embedder: any EmbeddingProvider) async throws {
    let memory = try await Memory(at: url, config: memoryConfig(embedder))
    try await memory.save(bulkyText)
    try await memory.save(alignedText)
    try await memory.flush()
    try await memory.close()
}

private func vectorRanking(_ memory: Memory) async throws -> [String] {
    let results = try await memory.search(probeQuery, options: .init(topK: 2, mode: .vectorOnly))
    #expect(results.diagnostics?.effectiveMode == .vectorOnly)
    return results.items.map(\.text)
}

private func expectSimilarityMismatch(_ error: any Error, sourceLocation: SourceLocation = #_sourceLocation) {
    let message = String(describing: error)
    #expect(message.contains("vector similarity mismatch"), "\(message)", sourceLocation: sourceLocation)
}

// MARK: - Ranking

@Test
func dotProductEmbedderRanksByInnerProductNotCosine() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: memoryConfig(KeyedEmbedder(similarity: .dotProduct)))
        try await memory.save(bulkyText)
        try await memory.save(alignedText)

        #expect(try await vectorRanking(memory) == [bulkyText, alignedText])
        try await memory.flush()
        #expect(try await vectorRanking(memory) == [bulkyText, alignedText])
        try await memory.close()
    }
}

@Test
func dotProductScoresAreRawInnerProducts() async throws {
    try await TempFiles.withTempFile { url in
        try await seed(url, with: KeyedEmbedder(similarity: .dotProduct))
        let memory = try await Memory(at: url, config: memoryConfig(KeyedEmbedder(similarity: .dotProduct)))
        let results = try await memory.search(probeQuery, options: .init(topK: 2, mode: .vectorOnly))
        let scores = Dictionary(uniqueKeysWithValues: results.items.map { ($0.text, $0.score) })
        // Inner products are 10 and 1; cosine would cap both at 1.
        #expect((scores[bulkyText] ?? 0) > 1.5)
        try await memory.close()
    }
}

@Test
func embeddingProviderSimilarityDefaultsToCosine() {
    #expect(UndeclaredSimilarityEmbedder().similarity == .cosine)
}

@Test
func undeclaredSimilarityStillRanksByCosine() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: memoryConfig(UndeclaredSimilarityEmbedder()))
        try await memory.save(bulkyText)
        try await memory.save(alignedText)
        try await memory.flush()
        #expect(try await vectorRanking(memory) == [alignedText, bulkyText])
        try await memory.close()
    }
}

@Test
func dotProductWithNormalizeRanksLikeCosine() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = KeyedEmbedder(similarity: .dotProduct, normalize: true)
        let memory = try await Memory(at: url, config: memoryConfig(embedder))
        try await memory.save(bulkyText)
        try await memory.save(alignedText)
        try await memory.flush()
        #expect(try await vectorRanking(memory) == [alignedText, bulkyText])
        try await memory.close()
    }
}

// MARK: - Both engines

@Test(arguments: [VectorEnginePreference.cpuOnly, .gpuOnly])
func dotProductRanksByInnerProductOnEachEngine(preference: VectorEnginePreference) async throws {
    #if canImport(Metal) && canImport(MetalANNS)
    if preference == .gpuOnly, MTLCreateSystemDefaultDevice() == nil { return }
    #else
    if preference == .gpuOnly { return }
    #endif
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        config.vectorEnginePreference = preference
        let embedder = KeyedEmbedder(similarity: .dotProduct)
        for reopen in [false, true] {
            let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
            let memory = Memory(orchestrator: orchestrator)
            if !reopen {
                try await memory.save(bulkyText)
                try await memory.save(alignedText)
            }
            #expect(try await vectorRanking(memory) == [bulkyText, alignedText], "reopen \(reopen)")
            try await memory.flush()
            try await memory.close()
        }
    }
}

// MARK: - Reopen with a different similarity

@Test(arguments: [
    (VectorSimilarity.cosine, VectorSimilarity.dotProduct),
    (VectorSimilarity.dotProduct, VectorSimilarity.cosine),
])
func reopenWithDifferentSimilarityThrows(written: VectorSimilarity, reopened: VectorSimilarity) async throws {
    try await TempFiles.withTempFile { url in
        try await seed(url, with: KeyedEmbedder(similarity: written))
        do {
            let memory = try await Memory(at: url, config: memoryConfig(KeyedEmbedder(similarity: reopened)))
            try await memory.close()
            Issue.record("expected a similarity mismatch reopening a \(written) store as \(reopened)")
        } catch {
            expectSimilarityMismatch(error)
        }

        // The refused open leaves the store usable with its own similarity.
        let memory = try await Memory(at: url, config: memoryConfig(KeyedEmbedder(similarity: written)))
        let expected = written == .dotProduct ? [bulkyText, alignedText] : [alignedText, bulkyText]
        #expect(try await vectorRanking(memory) == expected)
        try await memory.close()
    }
}

@Test
func reopenCosineStoreWithUndeclaredSimilarityKeepsWorking() async throws {
    try await TempFiles.withTempFile { url in
        try await seed(url, with: UndeclaredSimilarityEmbedder())
        let memory = try await Memory(at: url, config: memoryConfig(KeyedEmbedder(similarity: .cosine)))
        #expect(try await vectorRanking(memory) == [alignedText, bulkyText])
        try await memory.close()
    }
}

@Test
func dotProductStoreReopensWhileProviderLoadsThenAttaches() async throws {
    try await TempFiles.withTempFile { url in
        try await seed(url, with: KeyedEmbedder(similarity: .dotProduct))
        let gate = Gate()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: EmbeddingReadiness()
        ) {
            await gate.wait()
            return KeyedEmbedder(similarity: .dotProduct)
        }
        await gate.open()
        let status = try await waitForEmbedderSettled(memory)
        #expect(status == .active(KeyedEmbedder(similarity: .dotProduct).identity))
        #expect(try await vectorRanking(memory) == [bulkyText, alignedText])
        try await memory.close()
    }
}

@Test
func lateAttachWithDifferentSimilarityMarksEmbedderUnavailable() async throws {
    try await TempFiles.withTempFile { url in
        try await seed(url, with: KeyedEmbedder(similarity: .cosine))
        let gate = Gate()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: EmbeddingReadiness()
        ) {
            await gate.wait()
            return KeyedEmbedder(similarity: .dotProduct)
        }
        await gate.open()
        let status = try await waitForEmbedderSettled(memory)
        guard case .unavailable(let reason) = status else {
            Issue.record("expected unavailable after a similarity mismatch, got \(status)")
            try await memory.close()
            return
        }
        #expect(reason.contains("vector similarity mismatch"), "\(reason)")
        let text = try await memory.search(probeQuery, options: .init(topK: 2, mode: .textOnly))
        #expect(text.diagnostics?.effectiveMode == .textOnly)
        try await memory.close()
    }
}

@Test
func lateAttachOnEmptyStoreUsesProviderSimilarity() async throws {
    try await TempFiles.withTempFile { url in
        let gate = Gate()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: EmbeddingReadiness()
        ) {
            await gate.wait()
            return KeyedEmbedder(similarity: .dotProduct)
        }
        await gate.open()
        _ = try await waitForEmbedderSettled(memory)
        try await memory.save(bulkyText)
        try await memory.save(alignedText)
        try await memory.flush()
        #expect(try await vectorRanking(memory) == [bulkyText, alignedText])
        try await memory.close()

        let reopened = try await Memory(at: url, config: memoryConfig(KeyedEmbedder(similarity: .dotProduct)))
        #expect(try await vectorRanking(reopened) == [bulkyText, alignedText])
        try await reopened.close()
    }
}

// MARK: - Helpers

private func waitForEmbedderSettled(
    _ memory: Memory,
    timeout: Duration = .seconds(10)
) async throws -> EmbeddingStatus {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let status = await memory.stats().embeddingStatus
        switch status {
        case .active, .degraded, .unavailable:
            return status
        case .loading, .disabled:
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    throw SimilarityTestError.timedOut
}

private enum SimilarityTestError: Error {
    case timedOut
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
