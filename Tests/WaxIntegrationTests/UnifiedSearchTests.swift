import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
import Wax

@Test func textOnlySearch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("Swift programming language".utf8))
        try await text.index(frameId: id0, text: "Swift programming language")
        let id1 = try await wax.put(Data("Python programming language".utf8))
        try await text.index(frameId: id1, text: "Python programming language")

        try await text.commit()

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 10)
        let response = try await wax.search(request)

        #expect(response.results.count == 1)
        #expect(response.results[0].frameId == id0)
        #expect(response.results[0].previewText != nil)

        try await wax.close()
    }
}

@Test func vectorOnlySearch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 4)

        let id0 = try await vec.putWithEmbedding(Data("First".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
        _ = try await vec.putWithEmbedding(Data("Second".utf8), embedding: [0.0, 1.0, 0.0, 0.0])

        try await vec.commit()

        let queryEmbedding = VectorMath.normalizeL2([0.9, 0.1, 0.0, 0.0])
        let request = SearchRequest(embedding: queryEmbedding, mode: .vectorOnly, topK: 10)
        let response = try await wax.search(request)

        #expect(response.results.first?.frameId == id0)
        #expect(response.results.first?.previewText == "First")

        try await wax.close()
    }
}

@Test func hybridSearchOverlapRanksHighest() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 4)

        let id0 = try await vec.putWithEmbedding(Data("Swift programming".utf8), embedding: [0.0, 0.0, 0.0, 1.0])
        try await text.index(frameId: id0, text: "Swift programming")

        let id1 = try await vec.putWithEmbedding(Data("Swift is fast".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
        try await text.index(frameId: id1, text: "Swift is fast")

        try await text.commit()
        try await vec.commit()

        let request = SearchRequest(
            query: "Swift",
            embedding: [1.0, 0.0, 0.0, 0.0],
            mode: .hybrid(alpha: 0.5),
            topK: 10
        )
        let response = try await wax.search(request)

        #expect(response.results.first?.frameId == id1)
        #expect(response.results.first?.previewText != nil)

        try await wax.close()
    }
}

@Test func topKZeroReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("Swift".utf8))
        try await text.index(frameId: id0, text: "Swift")
        try await text.commit()

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 0)
        let response = try await wax.search(request)

        #expect(response.results.isEmpty)

        try await wax.close()
    }
}

@Test func filtersAllowResultsBeyondTopK() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 2)

        _ = try await vec.putWithEmbedding(Data("A".utf8), embedding: [1.0, 0.0])
        _ = try await vec.putWithEmbedding(Data("B".utf8), embedding: [0.9, 0.1])
        let id2 = try await vec.putWithEmbedding(Data("C".utf8), embedding: [0.1, 0.9])
        let id3 = try await vec.putWithEmbedding(Data("D".utf8), embedding: [0.0, 1.0])
        try await vec.commit()

        let allowlist = FrameFilter(frameIds: [id2, id3])
        let request = SearchRequest(
            embedding: [1.0, 0.0],
            mode: .vectorOnly,
            topK: 2,
            frameFilter: allowlist
        )
        let response = try await wax.search(request)

        let ids = Set(response.results.map(\.frameId))
        #expect(ids == Set([id2, id3]))

        try await wax.close()
    }
}

private struct TestEmbedder2D: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        VectorMath.normalizeL2([1.0, 0.0])
    }
}

#if canImport(Metal)
@Test
func metalVectorSearchNormalizesNonNormalizedQueryEmbedding() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.useMetalVectorSearch = true
        config.rag.searchMode = .vectorOnly

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: TestEmbedder2D()
        )
        try await orchestrator.remember("hello world")

        let result = try await orchestrator.recall(query: "hello", embedding: [2.0, 0.0])
        #expect(!result.items.isEmpty)

        try await orchestrator.close()
    }
}
#endif

@Test func vectorSearchWithoutManifestUsesPendingEmbeddings() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 2)

        let id0 = try await vec.putWithEmbedding(Data("Pending".utf8), embedding: [0.0, 1.0])

        let request = SearchRequest(
            embedding: [0.0, 1.0],
            mode: .vectorOnly,
            topK: 5
        )
        let response = try await wax.search(request)

        #expect(response.results.first?.frameId == id0)

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

@Test func vectorOnlySearchWithoutEmbeddingThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        do {
            _ = try await wax.search(SearchRequest(mode: .vectorOnly, topK: 5))
            Issue.record("Expected WaxError for vectorOnly search without embedding")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("requires a non-empty query embedding"))
        }

        try await wax.close()
    }
}
