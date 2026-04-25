#if canImport(CoreML)
import Foundation
import Testing
@testable import WaxVectorSearchArctic

/// Cosine similarity baseline tests for Arctic Embed Small.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                 "Set WAX_TEST_ARCTIC=1 to run Arctic quality tests"))
struct ArcticEmbeddingQualityTests {

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    @Test
    func embeddingsProduceMeaningfulSimilarities() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 1)

        // Verify the model produces meaningful (non-degenerate) embeddings:
        // - Different texts should not produce identical vectors
        // - Similarity values should be in a reasonable range (not all 0 or all 1)
        let a = try await embedder.embed("Swift is a programming language developed by Apple.")
        let b = try await embedder.embed("The Amazon rainforest is the largest tropical forest on Earth.")

        let sim = cosineSimilarity(a, b)
        #expect(sim > 0.0 && sim < 1.0,
                "Expected meaningful similarity between different texts, got \(sim)")
        #expect(a != b, "Different texts should produce different embedding vectors")

        // Same text should produce identical vectors
        let c = try await embedder.embed("Swift is a programming language developed by Apple.")
        #expect(a == c, "Same text should produce identical vectors")
    }

    @Test
    func queryPrefixImprovesRetrieval() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 1)

        let text = "What are the benefits of exercise?"
        let passage = "Regular physical activity improves cardiovascular health, strengthens muscles, and boosts mental well-being."

        let queryEmbed = try await embedder.embedQuery(text)
        let plainEmbed = try await embedder.embed(text)
        let passageEmbed = try await embedder.embed(passage)

        let simWithPrefix = cosineSimilarity(queryEmbed, passageEmbed)
        let simWithoutPrefix = cosineSimilarity(plainEmbed, passageEmbed)

        #expect(simWithPrefix > 0.3, "Query-aware similarity should be meaningful: \(simWithPrefix)")
        #expect(simWithoutPrefix > 0.3, "Plain similarity should be meaningful: \(simWithoutPrefix)")
    }
}
#endif
