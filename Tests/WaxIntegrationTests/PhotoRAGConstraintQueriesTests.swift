import Foundation
import CoreGraphics
import Testing
import Wax

private struct StubMultimodalEmbedder: MultimodalEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)

    func embed(text: String) async throws -> [Float] { [1, 0, 0, 0] }
    func embed(image: CGImage) async throws -> [Float] { [0, 1, 0, 0] }
}

@Test
func photoRAGTimeOnlyQueryUsesTimelineFallback() async throws {
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

        let tsA: Int64 = 1_700_000_000_000
        let tsB: Int64 = 1_700_000_100_000

        var metaA = Metadata()
        metaA.entries["photos.asset_id"] = "A"
        metaA.entries["photo.capture_ms"] = String(tsA)
        _ = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaA),
            compression: .plain,
            timestampMs: tsA
        )

        var metaB = Metadata()
        metaB.entries["photos.asset_id"] = "B"
        metaB.entries["photo.capture_ms"] = String(tsB)
        _ = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaB),
            compression: .plain,
            timestampMs: tsB
        )

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

        let start = Date(timeIntervalSince1970: TimeInterval(tsB - 1_000) / 1000)
        let end = Date(timeIntervalSince1970: TimeInterval(tsB + 1_000) / 1000)
        let query = PhotoQuery(
            text: nil,
            image: nil,
            timeRange: start...end,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.assetID == "B")
        try await orchestrator.flush()
    }
}

@Test
func photoRAGLocationOnlyRadiusZeroDoesNotFilterAll() async throws {
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

        let tsA: Int64 = 1_700_000_000_000
        let tsB: Int64 = 1_700_000_100_000

        var metaA = Metadata()
        metaA.entries["photos.asset_id"] = "A"
        metaA.entries["photo.capture_ms"] = String(tsA)
        metaA.entries["photo.location.lat"] = "37.3318"
        metaA.entries["photo.location.lon"] = "-122.0312"
        _ = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaA),
            compression: .plain,
            timestampMs: tsA
        )

        var metaB = Metadata()
        metaB.entries["photos.asset_id"] = "B"
        metaB.entries["photo.capture_ms"] = String(tsB)
        metaB.entries["photo.location.lat"] = "40.7128"
        metaB.entries["photo.location.lon"] = "-74.0060"
        _ = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaB),
            compression: .plain,
            timestampMs: tsB
        )

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

        let location = PhotoLocationQuery(
            center: PhotoCoordinate(latitude: 37.3318, longitude: -122.0312),
            radiusMeters: 0
        )
        let query = PhotoQuery(
            text: nil,
            image: nil,
            timeRange: nil,
            location: location,
            filters: .none,
            resultLimit: 2,
            contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(Set(ctx.items.map(\.assetID)) == ["A", "B"])
        try await orchestrator.flush()
    }
}

@Test
func photoRAGRecallAppliesLocalAvailabilityFilter() async throws {
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

        let timestamp: Int64 = 1_700_000_000_000

        var localMeta = Metadata()
        localMeta.entries[PhotoMetadataKey.assetID.rawValue] = "local-photo"
        localMeta.entries[PhotoMetadataKey.isLocal.rawValue] = "true"
        localMeta.entries[PhotoMetadataKey.source.rawValue] = PhotoSource.file.rawValue
        let localRoot = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: localMeta),
            compression: .plain,
            timestampMs: timestamp
        )
        let localText = "shared receipt token"
        let localSummary = try await session.put(
            Data(localText.utf8),
            options: FrameMetaSubset(kind: PhotoFrameKind.ocrSummary.rawValue, parentId: localRoot, metadata: localMeta),
            compression: .plain,
            timestampMs: timestamp
        )

        var remoteMeta = Metadata()
        remoteMeta.entries[PhotoMetadataKey.assetID.rawValue] = "icloud-only-photo"
        remoteMeta.entries[PhotoMetadataKey.isLocal.rawValue] = "false"
        remoteMeta.entries[PhotoMetadataKey.source.rawValue] = PhotoSource.photos.rawValue
        let remoteRoot = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: remoteMeta),
            compression: .plain,
            timestampMs: timestamp + 1
        )
        let remoteText = "shared receipt token"
        let remoteSummary = try await session.put(
            Data(remoteText.utf8),
            options: FrameMetaSubset(kind: PhotoFrameKind.ocrSummary.rawValue, parentId: remoteRoot, metadata: remoteMeta),
            compression: .plain,
            timestampMs: timestamp + 1
        )

        try await session.indexTextBatch(frameIds: [localSummary, remoteSummary], texts: [localText, remoteText])
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

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "receipt",
                filters: PhotoFilters(isLocal: true),
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
            )
        )

        #expect(ctx.items.map(\.assetID) == ["local-photo"])

        let remoteByAssetID = try await orchestrator.recall(
            PhotoQuery(
                text: "receipt",
                filters: PhotoFilters(assetIDs: ["icloud-only-photo"]),
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
            )
        )
        #expect(remoteByAssetID.items.map(\.assetID) == ["icloud-only-photo"])

        let remoteBySource = try await orchestrator.recall(
            PhotoQuery(
                text: "receipt",
                filters: PhotoFilters(source: .photos),
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
            )
        )
        #expect(remoteBySource.items.map(\.assetID) == ["icloud-only-photo"])

        try await orchestrator.flush()
    }
}
