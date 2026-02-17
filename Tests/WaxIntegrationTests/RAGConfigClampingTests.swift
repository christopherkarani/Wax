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
    let executionMode: ProviderExecutionMode = .onDeviceOnly

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
    textMeta.entries[PhotoMetadataKey.assetID.rawValue] = "photo-text"
    textMeta.entries[PhotoMetadataKey.captureMs.rawValue] = String(timestampMs)
    textMeta.entries[PhotoMetadataKey.isLocal.rawValue] = "true"
    _ = try await session.put(
        Data(),
        embedding: [1, 0, 0, 0],
        identity: nil,
        options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: textMeta),
        compression: .plain,
        timestampMs: timestampMs
    )

    var imageMeta = Metadata()
    imageMeta.entries[PhotoMetadataKey.assetID.rawValue] = "photo-image"
    imageMeta.entries[PhotoMetadataKey.captureMs.rawValue] = String(timestampMs)
    imageMeta.entries[PhotoMetadataKey.isLocal.rawValue] = "true"
    _ = try await session.put(
        Data(),
        embedding: [0, 1, 0, 0],
        identity: nil,
        options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: imageMeta),
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

private func firstAssetIDForPhotoBlendWeight(_ textEmbeddingWeight: Float) async throws -> String {
    try await TempFiles.withTempFile { url in
        try await writePhotoBlendFixtures(at: url)

        var config = defaultPhotoSearchConfig()
        config.textEmbeddingWeight = textEmbeddingWeight

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: BlendAwareEmbedder()
        )
        let result = try await orchestrator.recall(blendedPhotoQuery())
        guard let first = result.items.first else {
            throw WaxError.io("Expected at least one PhotoRAG result")
        }
        return first.assetID
    }
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
    let textPreferredFirst = try await firstAssetIDForPhotoBlendWeight(1.0)
    #expect(textPreferredFirst == "photo-text")

    let imagePreferredFirst = try await firstAssetIDForPhotoBlendWeight(0.0)
    #expect(imagePreferredFirst == "photo-image")
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

@Test
func fastRAGRrfKZeroOrNegativeDoesNotCrash() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeSimpleRAGStore(at: url)
        let builder = FastRAGContextBuilder()

        for value in [0, -1, -100] {
            var config = FastRAGConfig(searchMode: .textOnly)
            config.rrfK = value
            let context = try await builder.build(query: "Swift", wax: wax, config: config)
            #expect(!context.items.isEmpty)
        }

        try await wax.close()
    }
}

@Test
func fastRAGExpansionBudgetIsBoundedByContextBudget() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeSimpleRAGStore(at: url)
        let builder = FastRAGContextBuilder()
        let counter = try await TokenCounter()

        var config = FastRAGConfig(searchMode: .textOnly)
        config.maxContextTokens = 32
        config.expansionMaxTokens = 512

        let context = try await builder.build(query: "Swift", wax: wax, config: config)
        #expect(context.totalTokens <= config.maxContextTokens)
        if let expanded = context.items.first(where: { $0.kind == .expanded }) {
            #expect(await counter.count(expanded.text) <= config.maxContextTokens)
        }

        try await wax.close()
    }
}

@Test
func fastRAGMaxSnippetsZeroProducesNoSnippets() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeSimpleRAGStore(at: url)
        let builder = FastRAGContextBuilder()

        var config = FastRAGConfig(searchMode: .textOnly)
        config.maxSnippets = 0
        config.expansionMaxTokens = 0
        config.maxContextTokens = 128

        let context = try await builder.build(query: "Swift", wax: wax, config: config)
        #expect(context.items.allSatisfy { $0.kind != .snippet })

        try await wax.close()
    }
}

@Test
func fastRAGNegativeBudgetsClampToZeroAtBuildTime() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeSimpleRAGStore(at: url)
        let builder = FastRAGContextBuilder()

        var config = FastRAGConfig(searchMode: .textOnly)
        config.maxContextTokens = -1
        config.snippetMaxTokens = -100
        config.maxSnippets = -5
        config.expansionMaxTokens = -4
        config.maxSurrogates = -3
        config.surrogateMaxTokens = -2

        let context = try await builder.build(query: "Swift", wax: wax, config: config)
        #expect(context.totalTokens == 0)
        #expect(context.items.isEmpty)

        try await wax.close()
    }
}

@Test
func fastRAGSearchTopKZeroReturnsEmptyResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeSimpleRAGStore(at: url)
        let builder = FastRAGContextBuilder()

        var config = FastRAGConfig(searchMode: .textOnly)
        config.searchTopK = 0
        let context = try await builder.build(query: "Swift", wax: wax, config: config)
        #expect(context.items.isEmpty)
        #expect(context.totalTokens == 0)

        try await wax.close()
    }
}

@Test
func fastRAGPreviewMaxBytesZeroStillBuildsContext() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeSimpleRAGStore(at: url)
        let builder = FastRAGContextBuilder()

        var config = FastRAGConfig(searchMode: .textOnly)
        config.previewMaxBytes = 0
        let context = try await builder.build(query: "Swift", wax: wax, config: config)
        #expect(!context.items.isEmpty)

        try await wax.close()
    }
}

private func makeSimpleRAGStore(at url: URL) async throws -> Wax {
    let wax = try await Wax.create(at: url)
    let text = try await wax.enableTextSearch()

    let first = "Swift actors isolate state and structured concurrency coordinates tasks."
    let second = "Rust ownership and borrowing prevent data races."
    let third = "Temporal timeline queries retrieve recent memories."

    let firstId = try await wax.put(Data(first.utf8), options: FrameMetaSubset(searchText: first))
    let secondId = try await wax.put(Data(second.utf8), options: FrameMetaSubset(searchText: second))
    let thirdId = try await wax.put(Data(third.utf8), options: FrameMetaSubset(searchText: third))

    try await text.index(frameId: firstId, text: first)
    try await text.index(frameId: secondId, text: second)
    try await text.index(frameId: thirdId, text: third)
    try await text.commit()

    return wax
}
