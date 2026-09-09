import Foundation
import Testing
import WaxVectorSearch

/// Query/batch defaults on `EmbeddingProvider` dispatch through `any EmbeddingProvider`.
struct QueryAwareEmbeddingProtocolTests {
    @Test
    func queryOverrideDispatchesThroughAnyEmbeddingProvider() async throws {
        let erased: any EmbeddingProvider = PrefixQueryEmbedder()
        let text = "How does photosynthesis work?"
        let document = try await erased.embed(text)
        let query = try await erased.embedQuery(text)
        #expect(document != query)
        #expect(document.count == query.count)
    }

    @Test
    func defaultEmbedQueryMatchesEmbed() async throws {
        let erased: any EmbeddingProvider = PlainCountEmbedder()
        let text = "Simple test sentence"
        let document = try await erased.embed(text)
        let query = try await erased.embedQuery(text)
        #expect(document == query)
    }

    @Test
    func defaultBatchEmbedMapsSingleEmbed() async throws {
        let erased: any EmbeddingProvider = PlainCountEmbedder()
        let texts = ["a", "bb", "ccc"]
        let batch = try await erased.embed(batch: texts)
        var mapped: [[Float]] = []
        mapped.reserveCapacity(texts.count)
        for text in texts {
            mapped.append(try await erased.embed(text))
        }
        #expect(batch == mapped)
    }
}

private struct PrefixQueryEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 2
    let normalize = false
    let identity: EmbeddingIdentity? = nil

    func embed(_ text: String) async throws -> [Float] {
        [Float(text.utf8.count), 1]
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await embed("query: " + text)
    }
}

private struct PlainCountEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 2
    let normalize = false
    let identity: EmbeddingIdentity? = nil

    func embed(_ text: String) async throws -> [Float] {
        [Float(text.utf8.count), 0]
    }
}

#if canImport(CoreML)
import CoreML
@testable import WaxVectorSearchMiniLM
@testable import WaxVectorSearchArctic

/// Tests for the QueryAwareEmbeddingProvider protocol.
@Suite
struct QueryAwareEmbeddingTests {

    @Test
    func miniLMDoesNotConformToQueryAware() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        #expect(!(MiniLMEmbedder.self is any QueryAwareEmbeddingProvider.Type),
                "MiniLM should not conform to QueryAwareEmbeddingProvider")
    }

    @Test
    func arcticConformsToQueryAware() {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        func requireQueryAware<T: QueryAwareEmbeddingProvider>(_: T.Type) {}
        requireQueryAware(ArcticEmbedder.self)
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                    "Set WAX_TEST_ARCTIC=1 to run Arctic tests"))
    func arcticEmbedQueryProducesDifferentVectorThanEmbed() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
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

    @Test(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
                    "Set WAX_TEST_MINILM=1 to run MiniLM inference consistency tests"))
    func miniLMEmbedIsConsistentWithoutQueryPrefix() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
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

@available(macOS 15.0, iOS 18.0, *)
private func makeMiniLMEmbedderForTesting() throws -> MiniLMEmbedder {
    let modelConfiguration = MLModelConfiguration()
    modelConfiguration.computeUnits = .cpuOnly
    return try MiniLMEmbedder(
        config: .init(batchSize: 1, modelConfiguration: modelConfiguration)
    )
}
#endif
