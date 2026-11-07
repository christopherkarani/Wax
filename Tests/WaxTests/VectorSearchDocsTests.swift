import Foundation
import Testing

@Test
func vectorSearchDocsDoNotAdvertisePackageOnlyProtocolAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSearchEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package protocol VectorSearchEngine"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("ships two ``VectorSearchEngine`` implementations"))
        #expect(!doc.contains("ships two `VectorSearchEngine` implementations"))
        #expect(!doc.contains("implement the ``VectorSearchEngine`` protocol"))
        #expect(!doc.contains("Both engines share the ``VectorSearchEngine`` protocol"))
        #expect(!doc.contains("Both engines share the `VectorSearchEngine` protocol"))
        #expect(!doc.contains("- ``VectorSearchEngine``"))
    }
}

@Test
func vectorSearchDocsDoNotClaimProtocolHasStreamingBatchAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let protocolSource = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSearchEngine.swift"),
        encoding: .utf8
    )
    #expect(!protocolSource.contains("addBatchStreaming"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("addBatchStreaming"))
    }
}

@Test
func vectorSearchDocsDoNotInstantiatePackageOnlyAccelerateEngineAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/AccelerateVectorEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor AccelerateVectorEngine"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("AccelerateVectorEngine("))
    }
}

@Test
func vectorSearchDocsDoNotInstantiatePackageOnlyMetalEngineAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/MetalVectorEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor MetalVectorEngine"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("MetalVectorEngine("))
    }
}

@Test
func vectorEnginePreferenceIsPublicAPIAndDocsOmitDeprecatedEngineFlags() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSearchEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("public enum VectorEnginePreference"))
    #expect(!source.contains("package enum VectorEnginePreference"))

    let aliases = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PublicAliases.swift"),
        encoding: .utf8
    )
    #expect(aliases.contains("public typealias VectorEnginePreference = WaxVectorSearch.VectorEnginePreference"))

    for relativePath in vectorEnginePreferenceDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("useMetalVectorSearch"))
        #expect(!doc.contains("`.metalPreferred`"))
    }
}

@Test
func publicAPINamesBuiltInMultimodalEmbeddingsForPhotoVideoFacades() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let publicAPI = try String(
        contentsOf: repoRoot.appendingPathComponent("Resources/skills/public/wax/references/public-api.md"),
        encoding: .utf8
    )
    #expect(publicAPI.contains("PhotoMemory"))
    #expect(publicAPI.contains("VideoMemory"))
    #expect(publicAPI.contains("PhotoID"))
    #expect(publicAPI.contains("BuiltInMultimodalEmbeddings"))
    #expect(publicAPI.contains("BuiltInMultimodalEmbeddings.make"))
    #expect(!publicAPI.contains("wait for a facade"))

    for relativePath in [
        "Sources/Wax/Wax.docc/Articles/PhotoRAG.md",
        "Resources/website/docs/media/photo-rag.md",
        "Sources/Wax/Wax.docc/Articles/VideoRAG.md",
        "Resources/website/docs/media/video-rag.md",
    ] {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(doc.contains("BuiltInMultimodalEmbeddings"), "\(relativePath) must name BuiltInMultimodalEmbeddings")
        #expect(!doc.contains("wait for a stable public facade"))
        #expect(!doc.contains("wait for a facade"))
    }
}

@Test
func vectorSimilarityIsPublicAPIAndDocumentedWithNormalize() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift"),
        encoding: .utf8
    )
    #expect(source.contains("public enum VectorSimilarity"))
    #expect(source.contains("var similarity: VectorSimilarity { get }"))
    #expect(source.contains("var similarity: VectorSimilarity { .cosine }"))

    let aliases = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PublicAliases.swift"),
        encoding: .utf8
    )
    #expect(aliases.contains("public typealias VectorSimilarity = WaxVectorSearch.VectorSimilarity"))

    let publicAPI = try String(
        contentsOf: repoRoot.appendingPathComponent("Resources/skills/public/wax/references/public-api.md"),
        encoding: .utf8
    )
    #expect(publicAPI.contains("public enum VectorSimilarity"))
    #expect(publicAPI.contains("vector similarity mismatch"))

    for relativePath in [
        "Sources/WaxVectorSearch/WaxVectorSearch.docc/Articles/EmbeddingProviders.md",
        "Resources/website/docs/vector-search/embedding-providers.md",
    ] {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(doc.contains("var similarity: VectorSimilarity { get }"), "\(relativePath)")
        #expect(doc.contains("| `.dotProduct` | `true` |"), "\(relativePath) must document dot product with normalize")
        #expect(doc.contains("vector similarity mismatch"), "\(relativePath) must document the reopen mismatch")
    }
}

private let vectorSearchDocPaths = [
    "Sources/WaxVectorSearch/WaxVectorSearch.docc/Documentation.md",
    "Sources/WaxVectorSearch/WaxVectorSearch.docc/Articles/VectorSearchEngines.md",
    "Resources/website/docs/vector-search/vector-search-engines.md",
]

private let vectorEnginePreferenceDocPaths = [
    "Sources/WaxVectorSearch/WaxVectorSearch.docc/Documentation.md",
    "Sources/WaxVectorSearch/WaxVectorSearch.docc/Articles/VectorSearchEngines.md",
    "Resources/website/docs/vector-search/vector-search-engines.md",
    "Sources/Wax/Wax.docc/Articles/MemoryOrchestrator.md",
    "Resources/website/docs/orchestrator/memory-orchestrator.md",
    "Sources/Wax/Wax.docc/Articles/PhotoRAG.md",
    "Resources/website/docs/media/photo-rag.md",
    "Sources/Wax/Wax.docc/Articles/VideoRAG.md",
    "Resources/website/docs/media/video-rag.md",
]
