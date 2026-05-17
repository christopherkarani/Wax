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

@Test
func photoRAGPhotosRegionCropFailureDoesNotReturnBeforeSupersede() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    let photosIngestStart = try #require(source.range(of: "private func ingestOne(assetID: String)"))
    let localIngestStart = try #require(source[photosIngestStart.upperBound...].range(of: "private func ingestOne(file: PhotoFile)"))
    let photosIngestBody = source[photosIngestStart.lowerBound..<localIngestStart.lowerBound]

    #expect(photosIngestBody.contains("if let previousRoot"))
    #expect(!photosIngestBody.contains("guard !crops.isEmpty else { return }"))
}

@Test
func photoRAGRegionCropResultsUseCompactCropIndices() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    let photosIngestStart = try #require(source.range(of: "private func ingestOne(assetID: String)"))
    let localIngestStart = try #require(source[photosIngestStart.upperBound...].range(of: "private func ingestOne(file: PhotoFile)"))
    let localHelperStart = try #require(source[localIngestStart.upperBound...].range(of: "private func writeRegionEmbeddingsIfNeeded"))
    let rebuildIndexStart = try #require(source[localHelperStart.upperBound...].range(of: "private func rebuildIndex"))

    let photosIngestBody = source[photosIngestStart.lowerBound..<localIngestStart.lowerBound]
    let localRegionHelperBody = source[localHelperStart.lowerBound..<rebuildIndexStart.lowerBound]

    for regionEmbeddingBody in [photosIngestBody, localRegionHelperBody] {
        #expect(regionEmbeddingBody.contains("crops.append((crops.count, crop, region))"))
        #expect(!regionEmbeddingBody.contains("crops.append((i, crop, region))"))
        #expect(!regionEmbeddingBody.contains("crops.append((index, crop, region))"))
    }
}

@Test
func photoRAGDocsDoNotAdvertiseClassifierTags() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    #expect(source.contains("metadata.exif.keywords"))
    #expect(source.contains("if tags.isEmpty, let captionText"))

    for relativePath in photoRAGDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("Metadata keywords, or caption-derived search terms when no keywords are present"))
        #expect(doc.contains("Optional OCR, captions, metadata tags, and region evidence"))
        #expect(!doc.contains("Detected tags/labels"))
        #expect(!doc.contains("captions and tags"))
    }
}

private let photoRAGDocPaths = [
    "Sources/Wax/Wax.docc/Articles/PhotoRAG.md",
    "Resources/website/docs/media/photo-rag.md",
]
