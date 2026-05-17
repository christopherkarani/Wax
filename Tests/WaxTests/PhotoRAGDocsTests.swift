import Foundation
import Testing

@Test
func photoRAGDocsDoNotAdvertisePackageOnlyOrchestratorAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor PhotoRAGOrchestrator"))
    #expect(source.contains("package init("))

    for relativePath in photoRAGDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("PhotoRAGOrchestrator provides"))
        #expect(!doc.contains("let orchestrator = try await PhotoRAGOrchestrator("))
        #expect(!doc.contains("try await orchestrator.ingest"))
        #expect(!doc.contains("try await orchestrator.syncLibrary"))
        #expect(!doc.contains("try await orchestrator.recall"))
    }
}

@Test
func photoRAGDocsNameMultimodalEmbeddingProviderRequirement() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    #expect(source.contains("embedder: any MultimodalEmbeddingProvider"))

    for relativePath in photoRAGDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("MultimodalEmbeddingProvider"))
        #expect(!doc.contains("`EmbeddingProvider`"))
        #expect(!doc.contains("``EmbeddingProvider``"))
    }
}

@Test
func photoRAGFullLibrarySyncFetchesImagesOnly() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    let fullLibraryStart = try #require(source.range(of: "case .fullLibrary:"))
    let ingestStart = try #require(source[fullLibraryStart.upperBound...].range(of: "try await ingest(assetIDs: ids)"))
    let fullLibraryBody = source[fullLibraryStart.lowerBound..<ingestStart.lowerBound]

    #expect(fullLibraryBody.contains("PHAsset.fetchAssets(with: .image, options: opts)"))
    #expect(!fullLibraryBody.contains("PHAsset.fetchAssets(with: opts)"))
}

private let photoRAGDocPaths = [
    "Sources/Wax/Wax.docc/Articles/PhotoRAG.md",
    "Resources/website/docs/media/photo-rag.md",
]
