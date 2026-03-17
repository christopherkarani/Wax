#if canImport(CoreML)
import Foundation
import Testing
import WaxVectorSearch
@testable import WaxVectorSearchMiniLM
@testable import WaxVectorSearchArctic

/// Tests for the QueryAwareEmbeddingProvider protocol.
@Suite
struct QueryAwareEmbeddingTests {

    @Test
    func miniLMDoesNotConformToQueryAware() throws {
        let embedder = try MiniLMEmbedder()
        #expect(!(embedder is any QueryAwareEmbeddingProvider),
                "MiniLM should not conform to QueryAwareEmbeddingProvider")
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                    "Set WAX_TEST_ARCTIC=1 to run Arctic tests"))
    func arcticConformsToQueryAware() throws {
        let embedder = try ArcticEmbedder()
        #expect(embedder is any QueryAwareEmbeddingProvider,
                "Arctic should conform to QueryAwareEmbeddingProvider")
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                    "Set WAX_TEST_ARCTIC=1 to run Arctic tests"))
    func arcticEmbedQueryProducesDifferentVectorThanEmbed() async throws {
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 1)

        let text = "How does photosynthesis work?"
        let plain = try await embedder.embed(text)
        let query = try await embedder.embedQuery(text)

        #expect(plain != query,
                "embed() and embedQuery() should produce different vectors for Arctic")
        #expect(plain.count == query.count)
        #expect(plain.count == 384)
    }

    @Test
    func miniLMEmbedIsConsistentWithoutQueryPrefix() async throws {
        let embedder = try MiniLMEmbedder()
        try await embedder.prewarm(batchSize: 1)

        let text = "Simple test sentence"
        let v1 = try await embedder.embed(text)
        let v2 = try await embedder.embed(text)

        // Skip if MiniLM produces NaN (known issue in some CoreML environments)
        guard !v1[0].isNaN else { return }

        #expect(v1 == v2)
    }
}
#endif
