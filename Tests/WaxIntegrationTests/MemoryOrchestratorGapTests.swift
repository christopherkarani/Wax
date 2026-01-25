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
