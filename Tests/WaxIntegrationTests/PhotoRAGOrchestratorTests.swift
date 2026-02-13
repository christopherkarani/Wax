import Foundation
import CoreGraphics
import Testing
import Wax

private struct StubMultimodalEmbedder: MultimodalEmbeddingProvider {
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)

    func embed(text: String) async throws -> [Float] { [1, 0, 0, 0] }
    func embed(image: CGImage) async throws -> [Float] { [0, 1, 0, 0] }
}

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
            embedder: StubMultimodalEmbedder()
        )

        let query = PhotoQuery(
            text: "Costco",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: ContextBudget(maxTextTokens: 400, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 4)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.assetID == "A")
        #expect(ctx.items.first?.summaryText.contains("COSTCO") == true)
        try await orchestrator.flush()
    }
}

@Test
func photoRAGRejectsNetworkOCRProviderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await PhotoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: StubMultimodalEmbedder(),
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
            embedder: StubMultimodalEmbedder()
        )

        let query = PhotoQuery(
            text: "sunset",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: ContextBudget(maxTextTokens: 120, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 4)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.assetID == "A")
        #expect(ctx.items.first?.summaryText.contains("Tags:") == true)
        #expect(ctx.items.first?.summaryText.contains("beach, sunset") == true)

        try await orchestrator.flush()
    }
}
