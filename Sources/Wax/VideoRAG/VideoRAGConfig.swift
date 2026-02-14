import Foundation
import WaxVectorSearch

/// Configuration for `VideoRAGOrchestrator` (v1).
///
/// This configuration is intentionally host-app tunable: it trades off recall quality, latency,
/// battery, and store size for on-device RAG over video.
public struct VideoRAGConfig: Sendable, Equatable {
    /// Pipeline version string stamped into frame metadata for migration tracking.
    public var pipelineVersion: String

    // MARK: - Ingest

    /// Duration of each video segment in seconds (default: 10).
    public var segmentDurationSeconds: Double
    /// Overlap between adjacent segments in seconds (default: 0).
    public var segmentOverlapSeconds: Double
    /// Maximum number of segments per video (default: 360, covering 1 hour at 10s segments).
    public var maxSegmentsPerVideo: Int
    /// Number of segments to write per batch I/O operation.
    public var segmentWriteBatchSize: Int
    /// Maximum pixel dimension for keyframe images used for embedding.
    public var embedMaxPixelSize: Int
    /// Maximum transcript bytes stored per segment (default: 8KB).
    public var maxTranscriptBytesPerSegment: Int

    // MARK: - Search

    /// Number of candidate results fetched from the search engine before filtering.
    public var searchTopK: Int
    /// Balance between text and vector search in hybrid mode. 0.0 = vector only, 1.0 = text only.
    public var hybridAlpha: Float
    /// Preferred vector search engine (auto, Metal GPU, or CPU-only).
    public var vectorEnginePreference: VectorEnginePreference
    /// Maximum frames returned by timeline fallback when no text/vector results are found.
    public var timelineFallbackLimit: Int
    /// When true, validates that all providers declare `.onDeviceOnly` execution mode.
    public var requireOnDeviceProviders: Bool

    // MARK: - Output

    /// Whether to attach keyframe thumbnail bytes to recalled segments.
    public var includeThumbnailsInContext: Bool
    /// Maximum pixel dimension for keyframe thumbnails in output.
    public var thumbnailMaxPixelSize: Int

    // MARK: - Caching

    /// LRU cache capacity for query text embeddings. Set to 0 to disable caching.
    public var queryEmbeddingCacheCapacity: Int

    public init(
        pipelineVersion: String = "video_rag_v1",
        segmentDurationSeconds: Double = 10,
        segmentOverlapSeconds: Double = 0,
        maxSegmentsPerVideo: Int = 360,
        segmentWriteBatchSize: Int = 32,
        embedMaxPixelSize: Int = 512,
        maxTranscriptBytesPerSegment: Int = 8_192,
        searchTopK: Int = 400,
        hybridAlpha: Float = 0.5,
        vectorEnginePreference: VectorEnginePreference = .auto,
        timelineFallbackLimit: Int = 50,
        requireOnDeviceProviders: Bool = true,
        includeThumbnailsInContext: Bool = false,
        thumbnailMaxPixelSize: Int = 256,
        queryEmbeddingCacheCapacity: Int = 256
    ) {
        self.pipelineVersion = pipelineVersion
        self.segmentDurationSeconds = max(0, segmentDurationSeconds)
        self.segmentOverlapSeconds = max(0, segmentOverlapSeconds)
        self.maxSegmentsPerVideo = max(0, maxSegmentsPerVideo)
        self.segmentWriteBatchSize = max(1, segmentWriteBatchSize)
        self.embedMaxPixelSize = max(1, embedMaxPixelSize)
        self.maxTranscriptBytesPerSegment = max(0, maxTranscriptBytesPerSegment)
        self.searchTopK = max(0, searchTopK)
        self.hybridAlpha = Self.clamp01(hybridAlpha)
        self.vectorEnginePreference = vectorEnginePreference
        self.timelineFallbackLimit = max(0, timelineFallbackLimit)
        self.requireOnDeviceProviders = requireOnDeviceProviders
        self.includeThumbnailsInContext = includeThumbnailsInContext
        self.thumbnailMaxPixelSize = max(1, thumbnailMaxPixelSize)
        self.queryEmbeddingCacheCapacity = max(0, queryEmbeddingCacheCapacity)
    }

    @inline(__always)
    private static func clamp01(_ value: Float) -> Float {
        if value == .infinity { return 1 }
        if value == -.infinity { return 0 }
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    public static let `default` = VideoRAGConfig()
}
