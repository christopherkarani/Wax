import Foundation

/// Stable, type-safe identifier for a video across multiple ingestion sources.
public struct VideoID: Sendable, Hashable, Equatable {
    public enum Source: Sendable, Hashable, Equatable {
        case photos
        case file
    }

    public var source: Source
    public var id: String

    public init(source: Source, id: String) {
        self.source = source
        self.id = id
    }
}

/// Input item for file-based video ingestion.
public struct VideoFile: Sendable, Equatable {
    public var id: String
    public var url: URL
    public var captureDate: Date?

    public init(id: String, url: URL, captureDate: Date? = nil) {
        self.id = id
        self.url = url
        self.captureDate = captureDate
    }
}

/// Controls how much context is assembled for downstream models/agents.
public struct VideoContextBudget: Sendable, Equatable {
    public var maxTextTokens: Int
    public var maxThumbnails: Int
    public var maxTranscriptLinesPerSegment: Int

    public init(maxTextTokens: Int = 1_200, maxThumbnails: Int = 0, maxTranscriptLinesPerSegment: Int = 8) {
        self.maxTextTokens = max(0, maxTextTokens)
        self.maxThumbnails = max(0, maxThumbnails)
        self.maxTranscriptLinesPerSegment = max(0, maxTranscriptLinesPerSegment)
    }

    public static let `default` = VideoContextBudget()
}

/// Query parameters for Video RAG recall.
public struct VideoQuery: Sendable, Equatable {
    public var text: String?
    /// Optional capture-time filter for videos (using Wax frame timestamps).
    public var timeRange: ClosedRange<Date>?
    /// Optional allowlist of videos to search within.
    public var videoIDs: Set<VideoID>?
    /// Maximum number of videos to return.
    public var resultLimit: Int
    /// Maximum number of segments to include per video.
    public var segmentLimitPerVideo: Int
    public var contextBudget: VideoContextBudget

    public init(
        text: String? = nil,
        timeRange: ClosedRange<Date>? = nil,
        videoIDs: Set<VideoID>? = nil,
        resultLimit: Int = 12,
        segmentLimitPerVideo: Int = 3,
        contextBudget: VideoContextBudget = .default
    ) {
        self.text = text
        self.timeRange = timeRange
        self.videoIDs = videoIDs
        self.resultLimit = max(0, resultLimit)
        self.segmentLimitPerVideo = max(0, segmentLimitPerVideo)
        self.contextBudget = contextBudget
    }
}

/// Still thumbnail attached to a recalled segment (optional).
public struct VideoThumbnail: Sendable, Equatable {
    public enum Format: Sendable, Equatable { case png, jpeg }

    public var data: Data
    public var format: Format
    public var width: Int
    public var height: Int

    public init(data: Data, format: Format, width: Int, height: Int) {
        self.data = data
        self.format = format
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// A recalled video segment hit with timecodes and optional pixel payload.
public struct VideoSegmentHit: Sendable, Equatable {
    public enum Evidence: Sendable, Equatable { case vector, text(snippet: String?), timeline }

    public var startMs: Int64
    public var endMs: Int64
    public var score: Float
    public var evidence: [Evidence]
    public var transcriptSnippet: String?
    public var thumbnail: VideoThumbnail?

    public init(
        startMs: Int64,
        endMs: Int64,
        score: Float,
        evidence: [Evidence],
        transcriptSnippet: String? = nil,
        thumbnail: VideoThumbnail? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.score = score
        self.evidence = evidence
        self.transcriptSnippet = transcriptSnippet
        self.thumbnail = thumbnail
    }
}

/// A recalled video with grouped segment hits and a prompt-ready summary.
public struct VideoRAGItem: Sendable, Equatable {
    public var videoID: VideoID
    public var score: Float
    public var evidence: [VideoSegmentHit.Evidence]
    public var summaryText: String
    public var segments: [VideoSegmentHit]

    public init(videoID: VideoID, score: Float, evidence: [VideoSegmentHit.Evidence], summaryText: String, segments: [VideoSegmentHit]) {
        self.videoID = videoID
        self.score = score
        self.evidence = evidence
        self.summaryText = summaryText
        self.segments = segments
    }
}

/// Deterministic recall output suitable for prompting.
public struct VideoRAGContext: Sendable, Equatable {
    public struct Diagnostics: Sendable, Equatable {
        public var usedTextTokens: Int
        public var degradedVideoCount: Int

        public init(usedTextTokens: Int = 0, degradedVideoCount: Int = 0) {
            self.usedTextTokens = max(0, usedTextTokens)
            self.degradedVideoCount = max(0, degradedVideoCount)
        }
    }

    public var query: VideoQuery
    public var items: [VideoRAGItem]
    public var diagnostics: Diagnostics

    public init(query: VideoQuery, items: [VideoRAGItem], diagnostics: Diagnostics = .init()) {
        self.query = query
        self.items = items
        self.diagnostics = diagnostics
    }
}

/// Errors thrown during video ingestion.
public enum VideoIngestError: Error, Sendable, Equatable {
    case fileMissing(id: String, url: URL)
    case unsupportedPlatform(reason: String)
    case invalidVideo(reason: String)
    case embedderDimensionMismatch(expected: Int, got: Int)
}

