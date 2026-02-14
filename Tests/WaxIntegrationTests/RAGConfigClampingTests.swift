import CoreGraphics
import Foundation
import Testing
@testable import Wax

private let tinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII=")!
private let tinyPhotoQueryImage = PhotoQueryImage(data: tinyPNGData, format: .png)

private struct BlendAwareEmbedder: MultimodalEmbeddingProvider {
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(provider: "Test", model: "BlendAware", dimensions: 4, normalized: true)

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [0, 1, 0, 0]
    }
}

private func writePhotoBlendFixtures(at url: URL) async throws {
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

    let timestampMs: Int64 = 1_700_000_000_000

    var textMeta = Metadata()
    textMeta.entries["photos.asset_id"] = "photo-text"
    textMeta.entries["photo.capture_ms"] = String(timestampMs)
    textMeta.entries["photo.availability.local"] = "true"
    _ = try await session.put(
        Data(),
        embedding: [1, 0, 0, 0],
        identity: nil,
        options: FrameMetaSubset(kind: "photo.root", metadata: textMeta),
        compression: .plain,
        timestampMs: timestampMs
    )

    var imageMeta = Metadata()
    imageMeta.entries["photos.asset_id"] = "photo-image"
    imageMeta.entries["photo.capture_ms"] = String(timestampMs)
    imageMeta.entries["photo.availability.local"] = "true"
    _ = try await session.put(
        Data(),
        embedding: [0, 1, 0, 0],
        identity: nil,
        options: FrameMetaSubset(kind: "photo.root", metadata: imageMeta),
        compression: .plain,
        timestampMs: timestampMs
    )

    try await session.commit()
    await session.close()
    try await wax.close()
}

private func defaultPhotoSearchConfig() -> PhotoRAGConfig {
    var config = PhotoRAGConfig.default
    config.includeThumbnailsInContext = false
    config.includeRegionCropsInContext = false
    config.enableOCR = false
    config.enableRegionEmbeddings = false
    config.vectorEnginePreference = .cpuOnly
    config.searchTopK = 2
    return config
}

private func blendedPhotoQuery() -> PhotoQuery {
    PhotoQuery(
        text: "alpha",
        image: tinyPhotoQueryImage,
        timeRange: nil,
        location: nil,
        filters: .none,
        resultLimit: 2,
        contextBudget: ContextBudget(maxTextTokens: 120, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 1)
    )
}

@Test
func photoRAGConfigDefaultMatchesExplicitDefaults() {
    #expect(PhotoRAGConfig() == PhotoRAGConfig.default)
}

@Test
func photoRAGConfigClampsLimitsAndWeights() {
    let config = PhotoRAGConfig(
        ingestConcurrency: -5,
        embedMaxPixelSize: 0,
        ocrMaxPixelSize: -1,
        thumbnailMaxPixelSize: 0,
        enableRegionEmbeddings: false,
        maxRegionsPerPhoto: -1,
        maxOCRBlocksPerPhoto: 0,
        maxOCRSummaryLines: 0,
        regionEmbeddingConcurrency: 0,
        searchTopK: -99,
        hybridAlpha: -0.4,
        textEmbeddingWeight: 1.25,
        requireOnDeviceProviders: false,
        includeThumbnailsInContext: false,
        includeRegionCropsInContext: false,
        regionCropMaxPixelSize: 0,
        queryEmbeddingCacheCapacity: -16
    )

    #expect(config.ingestConcurrency == 1)
    #expect(config.embedMaxPixelSize == 1)
    #expect(config.ocrMaxPixelSize == 1)
    #expect(config.thumbnailMaxPixelSize == 1)
    #expect(config.maxRegionsPerPhoto == 0)
    #expect(config.maxOCRBlocksPerPhoto == 1)
    #expect(config.maxOCRSummaryLines == 1)
    #expect(config.regionEmbeddingConcurrency == 1)
    #expect(config.searchTopK == 0)
    #expect(config.hybridAlpha == 0.0)
    #expect(config.textEmbeddingWeight == 1.0)
    #expect(config.regionCropMaxPixelSize == 1)
    #expect(config.queryEmbeddingCacheCapacity == 0)
}

@Test
func photoRAGConfigClampsNonFiniteBlendValues() {
    let config = PhotoRAGConfig(
        hybridAlpha: Float.nan,
        textEmbeddingWeight: Float.nan
    )
    #expect(config.hybridAlpha == 0.5)
    #expect(config.textEmbeddingWeight == 0.5)

    let infConfig = PhotoRAGConfig(
        hybridAlpha: Float.infinity,
        textEmbeddingWeight: -Float.infinity
    )
    #expect(infConfig.hybridAlpha == 1.0)
    #expect(infConfig.textEmbeddingWeight == 0.0)
}

@Test
func photoRAGTextImageBlendWeightChangesOrdering() async throws {
    try await TempFiles.withTempFile { url in
        try await writePhotoBlendFixtures(at: url)

        let query = blendedPhotoQuery()

        var textPrefersConfig = defaultPhotoSearchConfig()
        textPrefersConfig.textEmbeddingWeight = 1.0
        let textPreferringOrchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: textPrefersConfig,
            embedder: BlendAwareEmbedder()
        )
        let textFirstResult = try await textPreferringOrchestrator.recall(query)
        #expect(textFirstResult.items.count >= 1)
        #expect(textFirstResult.items[0].assetID == "photo-text")

        var imagePrefersConfig = defaultPhotoSearchConfig()
        imagePrefersConfig.textEmbeddingWeight = 0.0
        let imagePreferringOrchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: imagePrefersConfig,
            embedder: BlendAwareEmbedder()
        )
        let imageFirstResult = try await imagePreferringOrchestrator.recall(query)
        #expect(imageFirstResult.items.count >= 1)
        #expect(imageFirstResult.items[0].assetID == "photo-image")
    }
}

@Test
func videoRAGConfigDefaultMatchesExplicitDefaults() {
    #expect(VideoRAGConfig() == VideoRAGConfig.default)
}

@Test
func videoRAGConfigClampsLimitsAndTopK() {
    let config = VideoRAGConfig(
        segmentDurationSeconds: -10,
        segmentOverlapSeconds: -3,
        maxSegmentsPerVideo: -4,
        segmentWriteBatchSize: 0,
        embedMaxPixelSize: 0,
        maxTranscriptBytesPerSegment: -2,
        searchTopK: -200,
        hybridAlpha: -0.4,
        timelineFallbackLimit: -9,
        thumbnailMaxPixelSize: 0,
        queryEmbeddingCacheCapacity: -11
    )

    #expect(config.segmentDurationSeconds == 0)
    #expect(config.segmentOverlapSeconds == 0)
    #expect(config.maxSegmentsPerVideo == 0)
    #expect(config.segmentWriteBatchSize == 1)
    #expect(config.embedMaxPixelSize == 1)
    #expect(config.maxTranscriptBytesPerSegment == 0)
    #expect(config.searchTopK == 0)
    #expect(config.hybridAlpha == 0.0)
    #expect(config.timelineFallbackLimit == 0)
    #expect(config.thumbnailMaxPixelSize == 1)
    #expect(config.queryEmbeddingCacheCapacity == 0)
}

@Test
func videoRAGConfigClampsNonFiniteHybridAlpha() {
    let config = VideoRAGConfig(
        hybridAlpha: Float.nan
    )
    #expect(config.hybridAlpha == 0.5)

    let infConfig = VideoRAGConfig(
        hybridAlpha: -Float.infinity
    )
    #expect(infConfig.hybridAlpha == 0.0)
}
