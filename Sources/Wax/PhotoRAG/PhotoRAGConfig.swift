import Foundation
import WaxVectorSearch

/// Configuration for `PhotoRAGOrchestrator`.
///
/// This configuration is intentionally host-app tunable: it trades off recall quality, latency,
/// battery, and store size for on-device RAG over photos.
public struct PhotoRAGConfig: Sendable, Equatable {
    /// Pipeline version string stamped into frame metadata for migration tracking.
    public var pipelineVersion: String

    // MARK: - Ingest

    /// Maximum number of concurrent asset ingestion tasks.
    public var ingestConcurrency: Int
    /// Maximum pixel dimension for the image used to compute the global embedding.
    public var embedMaxPixelSize: Int
    /// Maximum pixel dimension for the image used for OCR.
    public var ocrMaxPixelSize: Int
    /// Maximum pixel dimension for returned thumbnail images.
    public var thumbnailMaxPixelSize: Int
    /// Whether to run OCR on ingested photos.
    public var enableOCR: Bool
    /// Whether to compute per-region crop embeddings for spatial matching.
    public var enableRegionEmbeddings: Bool
    /// Maximum number of region crops to embed per photo.
    public var maxRegionsPerPhoto: Int

    // MARK: - OCR limits

    /// Maximum OCR text blocks stored per photo during ingest.
    public var maxOCRBlocksPerPhoto: Int
    /// Maximum lines in the OCR summary frame.
    public var maxOCRSummaryLines: Int
    /// Maximum concurrent region embedding tasks during ingest.
    public var regionEmbeddingConcurrency: Int

    // MARK: - Search

    /// Number of candidate results fetched from the search engine before filtering.
    public var searchTopK: Int
    /// Balance between text (BM25) and vector search in hybrid mode. 0.0 = vector only, 1.0 = text only.
    public var hybridAlpha: Float
    /// Preferred vector search engine (auto, Metal GPU, or CPU-only).
    public var vectorEnginePreference: VectorEnginePreference
    /// Weight for text embedding when fusing text + image query embeddings (0.0–1.0).
    /// The image weight is `1.0 - textEmbeddingWeight`.
    public var textEmbeddingWeight: Float
    /// When true, validates that all providers declare `.onDeviceOnly` execution mode.
    public var requireOnDeviceProviders: Bool

    // MARK: - Output

    /// Whether to attach PNG thumbnail bytes to recalled items.
    public var includeThumbnailsInContext: Bool
    /// Whether to attach region crop bytes to recalled items.
    public var includeRegionCropsInContext: Bool
    /// Maximum pixel dimension for region crop images in output.
    public var regionCropMaxPixelSize: Int

    // MARK: - Caching

    /// LRU cache capacity for query text embeddings. Set to 0 to disable caching.
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
        maxOCRBlocksPerPhoto: Int = 64,
        maxOCRSummaryLines: Int = 32,
        regionEmbeddingConcurrency: Int = 4,
        searchTopK: Int = 200,
        hybridAlpha: Float = 0.5,
        vectorEnginePreference: VectorEnginePreference = .auto,
        textEmbeddingWeight: Float = 0.6,
        requireOnDeviceProviders: Bool = true,
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
        self.maxOCRBlocksPerPhoto = max(1, maxOCRBlocksPerPhoto)
        self.maxOCRSummaryLines = max(1, maxOCRSummaryLines)
        self.regionEmbeddingConcurrency = max(1, regionEmbeddingConcurrency)
        self.searchTopK = max(0, searchTopK)
        self.hybridAlpha = Self.clamp01(hybridAlpha)
        self.vectorEnginePreference = vectorEnginePreference
        self.textEmbeddingWeight = Self.clamp01(textEmbeddingWeight)
        self.requireOnDeviceProviders = requireOnDeviceProviders
        self.includeThumbnailsInContext = includeThumbnailsInContext
        self.includeRegionCropsInContext = includeRegionCropsInContext
        self.regionCropMaxPixelSize = max(1, regionCropMaxPixelSize)
        self.queryEmbeddingCacheCapacity = max(0, queryEmbeddingCacheCapacity)
    }

    @inline(__always)
    private static func clamp01(_ value: Float) -> Float {
        if value == .infinity { return 1 }
        if value == -.infinity { return 0 }
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    public static let `default` = PhotoRAGConfig()
}
