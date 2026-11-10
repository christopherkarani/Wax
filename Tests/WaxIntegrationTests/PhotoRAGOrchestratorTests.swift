import Foundation
import CoreGraphics
import Testing
import Wax
import WaxTestSupport
import WaxCore

/// Text → `[1, 0, 0, 0]`, image → `[0, 1, 0, 0]`.
private let stubMultimodalEmbedder = DeterministicMultimodalEmbedder(
    identity: EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)
)

private struct NetworkOCRProvider: OCRProvider {
    var executionMode: ProviderExecutionMode { .mayUseNetwork }

    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        _ = image
        return []
    }
}

@Test
func photoRAGRecallReturnsAssetIDsFromOCR() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: true,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: 4
        )
        let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        let captureMs: Int64 = 1_700_000_000_000
        var metaA = Metadata()
        metaA.entries["photos.asset_id"] = "A"
        metaA.entries["photo.capture_ms"] = String(captureMs)

        let rootA = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaA),
            compression: .plain,
            timestampMs: captureMs
        )

        let ocrTextA = "COSTCO WHOLESALE\nTOTAL 42.00"
        let ocrA = try await session.put(
            Data(ocrTextA.utf8),
            options: FrameMetaSubset(kind: "photo.ocr.summary", role: .blob, parentId: rootA, metadata: metaA),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: ocrA, text: ocrTextA)

        var metaB = Metadata()
        metaB.entries["photos.asset_id"] = "B"
        metaB.entries["photo.capture_ms"] = String(captureMs)

        let rootB = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaB),
            compression: .plain,
            timestampMs: captureMs
        )

        let ocrTextB = "Hello World"
        let ocrB = try await session.put(
            Data(ocrTextB.utf8),
            options: FrameMetaSubset(kind: "photo.ocr.summary", role: .blob, parentId: rootB, metadata: metaB),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: ocrB, text: ocrTextB)

        try await session.commit()
        await session.close()
        try await wax.close()

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: stubMultimodalEmbedder
        )

        let query = PhotoQuery(
            text: "Costco",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: PhotoContextBudget(maxTextTokens: 400, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 4)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.photoID.id == "A")
        #expect(ctx.items.first?.summaryText.contains("COSTCO") == true)
        try await orchestrator.flush()
    }
}

#if canImport(Photos)
@Test
func photoRAGSyncLibraryWritesSyncStateCheckpoint() async throws {
    try await TempFiles.withTempFile { url in
        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: stubMultimodalEmbedder
        )

        try await orchestrator.syncLibrary(scope: .assetIDs([]))
        await orchestrator.session.close()
        try await orchestrator.wax.close()

        let reopened = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: stubMultimodalEmbedder
        )

        let syncState = await reopened.wax.frameMetas().filter {
            $0.kind == PhotoFrameKind.syncState.rawValue
        }
        #expect(syncState.count == 1)
        #expect(syncState.first?.metadata?.entries["photos.sync.scope"] == "asset_ids")
        #expect(syncState.first?.metadata?.entries["photos.sync.asset_count"] == "0")
        #expect(syncState.first?.metadata?.entries["photo.pipeline.version"] == config.pipelineVersion)
        let completedAt = syncState.first?.metadata?.entries["photos.sync.completed_at_ms"]
        #expect(completedAt.flatMap(Int64.init) != nil)

        try await reopened.flush()
        await reopened.session.close()
        try await reopened.wax.close()
    }
}
#endif

@Test
func photoRAGRejectsNetworkOCRProviderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await PhotoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: stubMultimodalEmbedder,
                ocr: NetworkOCRProvider(),
                captioner: nil
            )
            Issue.record("Expected WaxError for network OCR provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device OCR provider"))
        }
    }
}

@Test
func photoRAGRecallIncludesSearchableTagsFromIndexedFrames() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: true,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: 4
        )
        let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        let captureMs: Int64 = 1_700_000_000_000
        var rootMeta = Metadata()
        rootMeta.entries["photos.asset_id"] = "A"
        rootMeta.entries["photo.capture_ms"] = String(captureMs)

        let rootId = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: rootMeta),
            compression: .plain,
            timestampMs: captureMs
        )

        let tagsText = "beach, sunset, travel"
        let tagsId = try await session.put(
            Data(tagsText.utf8),
            options: FrameMetaSubset(kind: "photo.tags", parentId: rootId, metadata: rootMeta),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexTextBatch(frameIds: [tagsId], texts: [tagsText])

        try await session.commit()
        await session.close()
        try await wax.close()

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: stubMultimodalEmbedder
        )

        let query = PhotoQuery(
            text: "sunset",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: PhotoContextBudget(maxTextTokens: 120, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 4)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.photoID.id == "A")
        #expect(ctx.items.first?.summaryText.contains("Tags:") == true)
        #expect(ctx.items.first?.summaryText.contains("beach, sunset") == true)

        try await orchestrator.flush()
    }
}

private let ocrBlockOnlyToken = "zephyrtoken"

private func hasTextEvidence(_ item: PhotoRAGItem?, containing token: String) -> Bool {
    guard let item else { return false }
    return item.evidence.contains { evidence in
        if case .text(let snippet) = evidence {
            return snippet?.contains(token) == true
        }
        return false
    }
}

@Test
func photoRAGAssetFilteredRecallMatchesTextOnlyInOCRBlock() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-ocr-block-\(UUID().uuidString).png")
        let tinyPNG = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII="))
        try tinyPNG.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = true
        config.enableRegionEmbeddings = false
        config.maxOCRSummaryLines = 1
        config.vectorEnginePreference = .cpuOnly

        let ocr = StubOCRProvider(blocks: [
            RecognizedTextBlock(text: "summary line", bbox: PhotoNormalizedRect(x: 0, y: 0, width: 1, height: 0.5), confidence: 0.9),
            RecognizedTextBlock(text: ocrBlockOnlyToken, bbox: PhotoNormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5), confidence: 0.5),
        ])
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: stubMultimodalEmbedder,
            ocr: ocr,
            captioner: StubCaptionProvider(captionText: "a photo")
        )
        let photoID = PhotoID(source: .file, id: "ocr-block-photo")
        try await orchestrator.ingest(files: [PhotoFile(id: photoID, url: imageURL)])

        let budget = PhotoContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        let unfiltered = try await orchestrator.recall(
            PhotoQuery(text: ocrBlockOnlyToken, resultLimit: 5, contextBudget: budget)
        )
        #expect(hasTextEvidence(unfiltered.items.first, containing: ocrBlockOnlyToken))

        let filtered = try await orchestrator.recall(
            PhotoQuery(
                text: ocrBlockOnlyToken,
                filters: PhotoFilters(assetIDs: [photoID]),
                resultLimit: 5,
                contextBudget: budget
            )
        )
        #expect(filtered.items.map(\.photoID) == [photoID])
        #expect(hasTextEvidence(filtered.items.first, containing: ocrBlockOnlyToken))

        try await orchestrator.close()
    }
}

@Test
func photoRAGLocationFilteredRecallMatchesTextOnlyInOCRBlock() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: true,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: 4
        )
        let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        let captureMs: Int64 = 1_700_000_000_000
        var meta = Metadata()
        meta.entries[PhotoMetadataKey.assetID.rawValue] = "located"
        meta.entries[PhotoMetadataKey.captureMs.rawValue] = String(captureMs)
        meta.entries[PhotoMetadataKey.lat.rawValue] = "37.3318"
        meta.entries[PhotoMetadataKey.lon.rawValue] = "-122.0312"

        let root = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: meta),
            compression: .plain,
            timestampMs: captureMs
        )
        let block = try await session.put(
            Data(ocrBlockOnlyToken.utf8),
            options: FrameMetaSubset(kind: PhotoFrameKind.ocrBlock.rawValue, role: .blob, parentId: root, metadata: meta),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: block, text: ocrBlockOnlyToken)
        try await session.commit()
        await session.close()
        try await wax.close()

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: stubMultimodalEmbedder
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: ocrBlockOnlyToken,
                location: PhotoLocationQuery(
                    center: PhotoCoordinate(latitude: 37.3318, longitude: -122.0312),
                    radiusMeters: 1_000
                ),
                resultLimit: 5,
                contextBudget: PhotoContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
            )
        )
        #expect(ctx.items.map(\.photoID.id) == ["located"])
        #expect(hasTextEvidence(ctx.items.first, containing: ocrBlockOnlyToken))

        try await orchestrator.close()
    }
}
