import Foundation
import Testing
@testable import Wax

actor CountingEmbedder: EmbeddingProvider {
    nonisolated let dimensions: Int
    nonisolated let normalize: Bool
    nonisolated let identity: EmbeddingIdentity?

    private var count: Int = 0

    init(dimensions: Int, normalize: Bool) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = EmbeddingIdentity(
            provider: "bench",
            model: "counting",
            dimensions: dimensions,
            normalized: normalize
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        count += 1
        var hasher = FNV1a64()
        hasher.append(text)
        let seed = hasher.finalize()
        var state = seed
        var vector = [Float](repeating: 0, count: dimensions)
        for idx in vector.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let signed = Int64(bitPattern: state)
            vector[idx] = Float(signed) / Float(Int64.max)
        }
        return vector
    }

    func calls() -> Int { count }
}

@Test
func stagingLexIndexDoesNotChangeWhenNoTextMutations() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let content = "hello world"
        let id = try await wax.put(Data(content.utf8), options: FrameMetaSubset(searchText: content))
        try await text.index(frameId: id, text: content)

        try await text.stageForCommit()
        let stamp1 = await wax.stagedLexIndexStamp()
        #expect(stamp1 != nil)

        try await text.stageForCommit()
        let stamp2 = await wax.stagedLexIndexStamp()
        #expect(stamp1 == stamp2)

        try await wax.close()
    }
}

@Test
func stagingVecIndexDoesNotChangeWhenNoEmbeddingMutations() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 4)

        let content = "hello vectors"
        let embedding: [Float] = [0.1, 0.2, 0.3, 0.4]
        _ = try await vec.putWithEmbedding(
            Data(content.utf8),
            embedding: embedding,
            options: FrameMetaSubset(searchText: content)
        )

        try await vec.stageForCommit()
        let stamp1 = await wax.stagedVecIndexStamp()
        #expect(stamp1 != nil)

        try await vec.stageForCommit()
        let stamp2 = await wax.stagedVecIndexStamp()
        #expect(stamp1 == stamp2)

        try await wax.close()
    }
}

@Test
func embeddingCacheAvoidsReembeddingIdenticalChunks() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableTextSearch = false
        config.enableVectorSearch = true
        config.chunking = .tokenCount(targetTokens: 10_000, overlapTokens: 0)
        config.ingestConcurrency = 2
        config.embeddingCacheCapacity = 64

        let embedder = CountingEmbedder(dimensions: 8, normalize: false)
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)

        let content = "identical content"
        try await orchestrator.remember(content)
        try await orchestrator.remember(content)

        let calls = await embedder.calls()
        #expect(calls == 1)

        try await orchestrator.close()
    }
}

@Test
func frameMetasIncludingPendingReturnsCommittedAndPending() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let committedContent = "committed"
        let committedId = try await wax.put(
            Data(committedContent.utf8),
            options: FrameMetaSubset(searchText: committedContent)
        )
        try await wax.commit()

        let pendingContent = "pending"
        let pendingId = try await wax.put(
            Data(pendingContent.utf8),
            options: FrameMetaSubset(searchText: pendingContent)
        )

        let metas = await wax.frameMetasIncludingPending(frameIds: [committedId, pendingId])
        #expect(metas[committedId]?.searchText == committedContent)
        #expect(metas[pendingId]?.searchText == pendingContent)

        try await wax.close()
    }
}

@Test
func framePreviewsBatchMatchesSinglePreview() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let contentA = "alpha preview text"
        let contentB = "beta preview text"
        let idA = try await wax.put(Data(contentA.utf8))
        let idB = try await wax.put(Data(contentB.utf8))
        try await wax.commit()

        let maxBytes = 8
        let batch = try await wax.framePreviews(frameIds: [idA, idB], maxBytes: maxBytes)
        let singleA = try await wax.framePreview(frameId: idA, maxBytes: maxBytes)
        let singleB = try await wax.framePreview(frameId: idB, maxBytes: maxBytes)

        #expect(batch[idA] == singleA)
        #expect(batch[idB] == singleB)

        try await wax.close()
    }
}

@Test
func pendingEmbeddingMutationsSinceReturnsIncremental() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let idA = try await wax.put(Data("A".utf8))
        let idB = try await wax.put(Data("B".utf8))
        try await wax.putEmbedding(frameId: idA, vector: [0.1, 0.2, 0.3, 0.4])
        try await wax.putEmbedding(frameId: idB, vector: [0.4, 0.3, 0.2, 0.1])

        let initial = await wax.pendingEmbeddingMutations(since: nil)
        #expect(initial.embeddings.count == 2)
        let lastSeq = initial.latestSequence

        let none = await wax.pendingEmbeddingMutations(since: lastSeq)
        #expect(none.embeddings.isEmpty)

        let idC = try await wax.put(Data("C".utf8))
        try await wax.putEmbedding(frameId: idC, vector: [0.9, 0.8, 0.7, 0.6])

        let next = await wax.pendingEmbeddingMutations(since: lastSeq)
        #expect(next.embeddings.count == 1)

        do {
            try await wax.close()
            Issue.record("Expected close to propagate auto-commit failure for pending embeddings")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("vector index must be staged before committing embeddings"))
        }
    }
}

// TODO: Implement _resetBpeCacheStats and _bpeCacheStats on TokenCounter
// @Test
// func tokenCounterBpeLoadsOncePerEncoding() async throws {
//     await TokenCounter._resetBpeCacheStats()
//     _ = try await TokenCounter()
//     _ = try await TokenCounter()
//     let stats = await TokenCounter._bpeCacheStats()
//     #expect(stats.loadCount == 1)
// }
