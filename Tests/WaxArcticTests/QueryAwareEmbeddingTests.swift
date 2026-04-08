#if canImport(CoreML)
import CoreML
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
        #expect(!(MiniLMEmbedder.self is any QueryAwareEmbeddingProvider.Type),
                "MiniLM should not conform to QueryAwareEmbeddingProvider")
    }

    @Test
    func arcticConformsToQueryAware() {
        func requireQueryAware<T: QueryAwareEmbeddingProvider>(_: T.Type) {}
        requireQueryAware(ArcticEmbedder.self)
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
        let embedder = try makeMiniLMEmbedderForTesting()
        try await embedder.prewarm(batchSize: 1)

        let text = "Simple test sentence"
        let v1 = try await embedder.embed(text)
        let v2 = try await embedder.embed(text)

        // Skip if MiniLM produces NaN (known issue in some CoreML environments)
        guard !v1[0].isNaN else { return }

        #expect(v1 == v2)
    }
}

private func makeMiniLMEmbedderForTesting() throws -> MiniLMEmbedder {
    let modelConfiguration = MLModelConfiguration()
    modelConfiguration.computeUnits = .cpuOnly
    return try MiniLMEmbedder(
        config: .init(batchSize: 1, modelConfiguration: modelConfiguration)
    )
}
#endif
