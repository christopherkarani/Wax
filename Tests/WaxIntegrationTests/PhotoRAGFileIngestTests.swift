#if canImport(ImageIO)
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
import Wax

private let photoFileTinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII=")!

@Test
func photoRAGIngestsLocalImageFilesAndRecallsCaptionMetadata() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-local-photo-\(UUID().uuidString).png")
        try photoFileTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: DeterministicMultimodalEmbedder(),
            captioner: StubCaptionProvider(captionText: "local receipt image")
        )

        try await orchestrator.ingest(files: [
            PhotoFile(id: "local-fixture", url: imageURL, captureDate: Date(timeIntervalSince1970: 1_700_000_000))
        ])

        let context = try await orchestrator.recall(
            PhotoQuery(
                text: "receipt",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0)
            )
        )
        #expect(context.items.first?.assetID == "local-fixture")
        #expect(context.items.first?.summaryText.contains("local receipt image") == true)

        let rootId = try #require(await orchestrator.wax.frameMetas().first {
            $0.kind == PhotoFrameKind.root.rawValue
                && $0.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == "local-fixture"
        }?.id)
        let rootMeta = try await orchestrator.wax.frameMeta(frameId: rootId)
        #expect(rootMeta.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == "local-fixture")
        #expect(rootMeta.metadata?.entries["photo.source"] == "file")
        #expect(rootMeta.metadata?.entries["photo.file_url"] == imageURL.absoluteString)

        try await orchestrator.flush()
    }
}

@Test
func photoRAGFileIngestEmptyFilesArrayIsNoOp() async throws {
    try await TempFiles.withTempFile { storeURL in
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: .default,
            embedder: DeterministicMultimodalEmbedder()
        )

        try await orchestrator.ingest(files: [])
        try await orchestrator.flush()

        let roots = await orchestrator.wax.frameMetas().filter { $0.kind == PhotoFrameKind.root.rawValue }
        #expect(roots.isEmpty)
    }
}

@Test
func photoRAGFileIngestMissingFileThrowsTypedError() async throws {
    try await TempFiles.withTempFile { storeURL in
        let missingURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString).png")
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: .default,
            embedder: DeterministicMultimodalEmbedder()
        )

        do {
            try await orchestrator.ingest(files: [PhotoFile(id: "missing", url: missingURL)])
            Issue.record("Expected missing local photo file to throw")
        } catch let error as PhotoIngestError {
            guard case let .fileMissing(id, url) = error else {
                Issue.record("Expected .fileMissing, got \(error)")
                return
            }
            #expect(id == "missing")
            #expect(url == missingURL)
        }
    }
}

@Test
func photoRAGLocalFileRecallSurvivesMissingPixelSource() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-local-deleted-\(UUID().uuidString).png")
        try photoFileTinyPNGData.write(to: imageURL)

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = true
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: DeterministicMultimodalEmbedder(),
            captioner: StubCaptionProvider(captionText: "deleted source caption")
        )
        try await orchestrator.ingest(files: [PhotoFile(id: "deleted-file", url: imageURL)])
        try FileManager.default.removeItem(at: imageURL)

        let context = try await orchestrator.recall(
            PhotoQuery(
                text: "deleted",
                resultLimit: 1,
                contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 1, maxRegions: 0)
            )
        )
        #expect(context.items.first?.assetID == "deleted-file")
        #expect(context.items.first?.thumbnail == nil)
    }
}

@Test
func photoRAGLocalFileIngestWritesRegionEmbeddingsWhenEnabled() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-local-region-\(UUID().uuidString).png")
        try photoFileTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = true
        config.enableRegionEmbeddings = true
        config.maxRegionsPerPhoto = 1
        config.vectorEnginePreference = .cpuOnly

        let ocr = StubOCRProvider(blocks: [
            RecognizedTextBlock(
                text: "region token",
                bbox: PhotoNormalizedRect(x: 0, y: 0, width: 1, height: 1),
                confidence: 0.9
            ),
        ])
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: DeterministicMultimodalEmbedder(),
            ocr: ocr,
            captioner: StubCaptionProvider(captionText: "region caption")
        )

        try await orchestrator.ingest(files: [PhotoFile(id: "region-file", url: imageURL)])

        let metas = await orchestrator.wax.frameMetas()
        #expect(metas.contains { meta in
            meta.kind == PhotoFrameKind.region.rawValue
                && meta.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == "region-file"
        })
    }
}
#endif
