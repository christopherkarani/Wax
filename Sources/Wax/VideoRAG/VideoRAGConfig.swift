import Foundation
import WaxVectorSearch

/// Configuration for `VideoRAGOrchestrator` (v1).
///
/// This configuration is intentionally host-app tunable: it trades off recall quality, latency,
/// battery, and store size for on-device RAG over video.
public struct VideoRAGConfig: Sendable, Equatable {
    public var pipelineVersion: String

    // Ingest
    public var segmentDurationSeconds: Double
    public var segmentOverlapSeconds: Double
    public var maxSegmentsPerVideo: Int
    public var segmentWriteBatchSize: Int
    public var embedMaxPixelSize: Int
    public var maxTranscriptBytesPerSegment: Int

    // Search
    public var searchTopK: Int
    public var hybridAlpha: Float
    public var vectorEnginePreference: VectorEnginePreference
    public var timelineFallbackLimit: Int

    // Output
    public var includeThumbnailsInContext: Bool
    public var thumbnailMaxPixelSize: Int

    // Caching
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
        self.hybridAlpha = min(1, max(0, hybridAlpha))
        self.vectorEnginePreference = vectorEnginePreference
        self.timelineFallbackLimit = max(0, timelineFallbackLimit)
        self.includeThumbnailsInContext = includeThumbnailsInContext
        self.thumbnailMaxPixelSize = max(1, thumbnailMaxPixelSize)
        self.queryEmbeddingCacheCapacity = max(0, queryEmbeddingCacheCapacity)
    }

    public static let `default` = VideoRAGConfig()
}

