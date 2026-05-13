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
func vectorSearchDocsDoNotInstantiatePackageOnlyUSearchEngineAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/USearchVectorEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor USearchVectorEngine"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("USearchVectorEngine("))
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
func docsDoNotExposePackageOnlyVectorEnginePreferenceAsPublicConfig() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSearchEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package enum VectorEnginePreference"))

    for relativePath in vectorEnginePreferenceDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("VectorEnginePreference"))
        #expect(!doc.contains("vectorEnginePreference"))
        #expect(!doc.contains("useMetalVectorSearch"))
        #expect(!doc.contains("`.gpuOnly`"))
        #expect(!doc.contains("`.cpuOnly`"))
        #expect(!doc.contains("`.metalPreferred`"))
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
