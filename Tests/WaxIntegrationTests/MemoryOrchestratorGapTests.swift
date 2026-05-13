import Foundation
import Testing
import Wax
import WaxCore

@Test
func memoryOrchestratorRecallUsesVectorEmbedding() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = false // Disable text search to rely solely on vectors
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 5,
            searchMode: .vectorOnly // Enforce vector only
        )

        let embedder = TestEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        
        // Ingest: "Hello World" -> Embedder returns [0.5, 0.5] (deterministic)
        try await orchestrator.remember("Hello World", metadata: ["id": "1"])
        try await orchestrator.flush()

        // Recall: "Hello World" -> Embedder returns [0.5, 0.5]
        // If MemoryOrchestrator doesn't embed the query, embedding is nil, search returns empty.
        let ctx = try await orchestrator.recall(query: "Hello World")
        
        #expect(!ctx.items.isEmpty, "Recall should return items using vector search")
        if let first = ctx.items.first {
            #expect(first.text.contains("Hello World"))
        }

        try await orchestrator.close()
    }
}

private struct TestEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        // Simple deterministic embedding
        // For "Hello World", count is 11.
        return VectorMath.normalizeL2([0.5, 0.5])
    }
}

private struct NetworkEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Network",
        dimensions: 2,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .mayUseNetwork

    func embed(_ text: String) async throws -> [Float] {
        return VectorMath.normalizeL2([0.5, 0.5])
    }
}

@Test
func memoryOrchestratorRejectsNetworkEmbedderByDefault() async throws {
    await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        do {
            _ = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: NetworkEmbedder()
            )
            Issue.record("Expected WaxError for network embedding provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device embedding provider"))
        } catch {
            Issue.record("Expected WaxError, got \(error)")
        }
    }
}

@Test
func whitespaceOnlyRecallDoesNotRequestEmbedding() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true

        let embedder = WhitespaceRecallCountingEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)

        let context = try await orchestrator.recall(query: " \n\t ", embeddingPolicy: .ifAvailable)

        #expect(context.items.isEmpty)
        #expect(await embedder.callCount == 0)

        try await orchestrator.close()
    }
}

private actor WhitespaceRecallCountingEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Counting",
        dimensions: 2,
        normalized: true
    )

    private var calls = 0

    var callCount: Int {
        calls
    }

    func embed(_ text: String) async throws -> [Float] {
        calls += 1
        return VectorMath.normalizeL2([1.0, 0.0])
    }
}
