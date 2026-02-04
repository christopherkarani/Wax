import Foundation
import WaxVectorSearch

/// Configuration for `PhotoRAGOrchestrator`.
///
/// This configuration is intentionally host-app tunable: it trades off recall quality, latency,
/// battery, and store size for on-device RAG over photos.
public struct PhotoRAGConfig: Sendable, Equatable {
    public var pipelineVersion: String

    // Ingest
    public var ingestConcurrency: Int
    public var embedMaxPixelSize: Int
    public var ocrMaxPixelSize: Int
    public var thumbnailMaxPixelSize: Int
    public var enableOCR: Bool
    public var enableRegionEmbeddings: Bool
    public var maxRegionsPerPhoto: Int

    // Search
    public var searchTopK: Int
    public var hybridAlpha: Float
    public var vectorEnginePreference: VectorEnginePreference

    // Output
    public var includeThumbnailsInContext: Bool
    public var includeRegionCropsInContext: Bool
    public var regionCropMaxPixelSize: Int

    // Caching
    public var queryEmbeddingCacheCapacity: Int

    public init(
        pipelineVersion: String = "photo_rag_v1",
        ingestConcurrency: Int = 2,
        embedMaxPixelSize: Int = 512,
        ocrMaxPixelSize: Int = 1024,
        thumbnailMaxPixelSize: Int = 256,
        enableOCR: Bool = true,
        enableRegionEmbeddings: Bool = true,
        maxRegionsPerPhoto: Int = 8,
        searchTopK: Int = 200,
        hybridAlpha: Float = 0.5,
        vectorEnginePreference: VectorEnginePreference = .auto,
        includeThumbnailsInContext: Bool = true,
        includeRegionCropsInContext: Bool = true,
        regionCropMaxPixelSize: Int = 1024,
        queryEmbeddingCacheCapacity: Int = 256
    ) {
        self.pipelineVersion = pipelineVersion
        self.ingestConcurrency = max(1, ingestConcurrency)
        self.embedMaxPixelSize = max(1, embedMaxPixelSize)
        self.ocrMaxPixelSize = max(1, ocrMaxPixelSize)
        self.thumbnailMaxPixelSize = max(1, thumbnailMaxPixelSize)
        self.enableOCR = enableOCR
        self.enableRegionEmbeddings = enableRegionEmbeddings
        self.maxRegionsPerPhoto = max(0, maxRegionsPerPhoto)
        self.searchTopK = max(0, searchTopK)
        self.hybridAlpha = min(1, max(0, hybridAlpha))
        self.vectorEnginePreference = vectorEnginePreference
        self.includeThumbnailsInContext = includeThumbnailsInContext
        self.includeRegionCropsInContext = includeRegionCropsInContext
        self.regionCropMaxPixelSize = max(1, regionCropMaxPixelSize)
        self.queryEmbeddingCacheCapacity = max(0, queryEmbeddingCacheCapacity)
    }

    public static let `default` = PhotoRAGConfig()
}
