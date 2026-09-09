import Foundation
import Testing
import Wax

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

        #expect(doc.contains("PhotoMemory"))
        #expect(doc.contains("BuiltInMultimodalEmbeddings"))
        #expect(!doc.contains("wait for a stable public facade"))
        #expect(!doc.contains("wait for a facade"))
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
    let photosIngestStart = try #require(source.range(of: "private func ingestOne(photoID: PhotoID)"))
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
    let photosIngestStart = try #require(source.range(of: "private func ingestOne(photoID: PhotoID)"))
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
func photoIDMatchesVideoIDShapeInPublicTypes() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let photoTypes = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGTypes.swift"),
        encoding: .utf8
    )
    let videoTypes = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/VideoRAG/VideoRAGTypes.swift"),
        encoding: .utf8
    )

    #expect(photoTypes.contains("public struct PhotoID: Sendable, Hashable, Equatable"))
    #expect(photoTypes.contains("public enum Source: Sendable, Hashable, Equatable { case photos, file }")
        || (photoTypes.contains("public enum Source: Sendable, Hashable, Equatable")
            && photoTypes.contains("case photos")
            && photoTypes.contains("case file")))
    #expect(photoTypes.contains("public var source: Source"))
    #expect(photoTypes.contains("public var id: String"))
    #expect(photoTypes.contains("public init(source: Source, id: String)"))

    #expect(videoTypes.contains("public struct VideoID: Sendable, Hashable, Equatable"))
    #expect(photoTypes.contains("public var id: PhotoID"))
    #expect(photoTypes.contains("public var assetIDs: Set<PhotoID>?"))
    #expect(photoTypes.contains("case assetIDs([PhotoID])"))
    #expect(photoTypes.contains("public var photoID: PhotoID"))

    let photo = PhotoID(source: .file, id: "receipt-1")
    let photosLibrary = PhotoID(source: .photos, id: "receipt-1")
    let video = VideoID(source: .file, id: "receipt-1")
    #expect(photo != photosLibrary)
    #expect(photo.id == video.id)
    #expect(Set([photo, photo]).count == 1)

    let fileURL = URL(fileURLWithPath: "/tmp/receipt-1.png")
    #expect(PhotoFile(id: photo, url: fileURL).id == photo)
    #expect(PhotoFile(id: photosLibrary, url: fileURL).id == photo)
    #expect(PhotoFile(id: "receipt-1", url: fileURL).id == photo)
}

@Test
func photoMemoryDeleteRequiresPhotoIDNotStringOrVideoID() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let photoMemory = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoMemory.swift"),
        encoding: .utf8
    )
    let orchestrator = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )

    #expect(photoMemory.contains("public func delete(photoID: PhotoID)"))
    #expect(!photoMemory.contains("public func delete(assetID: String)"))
    #expect(!photoMemory.contains("func delete(photoID: VideoID)"))
    #expect(!photoMemory.contains("func delete(videoID:"))
    #expect(orchestrator.contains("package func delete(photoID: PhotoID)"))
    #expect(!orchestrator.contains("package func delete(assetID: String)"))
    #expect(!orchestrator.contains("func delete(photoID: VideoID)"))
}

@Test
func publicAPINamesPhotoIDForExperimentalPhotoIdentity() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let publicAPI = try String(
        contentsOf: repoRoot.appendingPathComponent("Resources/skills/public/wax/references/public-api.md"),
        encoding: .utf8
    )
    #expect(publicAPI.contains("`PhotoID`"))
    #expect(publicAPI.contains("PhotoID(source:"))
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
