import Foundation

/// Stable, type-safe identifier for a video across multiple ingestion sources.
package struct VideoID: Sendable, Hashable, Equatable {
    package enum Source: Sendable, Hashable, Equatable {
        case photos
        case file
    }

    package var source: Source
    package var id: String

    package init(source: Source, id: String) {
        self.source = source
        self.id = id
    }
}

/// Input item for file-based video ingestion.
package struct VideoFile: Sendable, Equatable {
    package var id: String
    package var url: URL
    package var captureDate: Date?

    package init(id: String, url: URL, captureDate: Date? = nil) {
        self.id = id
        self.url = url
        self.captureDate = captureDate
    }
}

/// Controls how much context is assembled for downstream models/agents.
package struct VideoContextBudget: Sendable, Equatable {
    package var maxTextTokens: Int
    package var maxThumbnails: Int
    package var maxTranscriptLinesPerSegment: Int

    package init(maxTextTokens: Int = 1_200, maxThumbnails: Int = 0, maxTranscriptLinesPerSegment: Int = 8) {
        self.maxTextTokens = max(0, maxTextTokens)
        self.maxThumbnails = max(0, maxThumbnails)
        self.maxTranscriptLinesPerSegment = max(0, maxTranscriptLinesPerSegment)
    }

    package static let `default` = VideoContextBudget()
}

/// Query parameters for Video RAG recall.
package struct VideoQuery: Sendable, Equatable {
    package var text: String?
    /// Optional capture-time filter for videos (using Wax frame timestamps).
    package var timeRange: ClosedRange<Date>?
    /// Optional allowlist of videos to search within.
    package var videoIDs: Set<VideoID>?
    /// Maximum number of videos to return.
    package var resultLimit: Int
    /// Maximum number of segments to include per video.
    package var segmentLimitPerVideo: Int
    package var contextBudget: VideoContextBudget

    package init(
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
package struct VideoThumbnail: Sendable, Equatable {
    package enum Format: Sendable, Equatable { case png, jpeg }

    package var data: Data
    package var format: Format
    package var width: Int
    package var height: Int

    package init(data: Data, format: Format, width: Int, height: Int) {
        self.data = data
        self.format = format
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// A recalled video segment hit with timecodes and optional pixel payload.
package struct VideoSegmentHit: Sendable, Equatable {
    package enum Evidence: Sendable, Equatable { case vector, text(snippet: String?), timeline }

    package var startMs: Int64
    package var endMs: Int64
    package var score: Float
    package var evidence: [Evidence]
    package var transcriptSnippet: String?
    package var thumbnail: VideoThumbnail?

    package init(
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
package struct VideoRAGItem: Sendable, Equatable {
    package var videoID: VideoID
    package var score: Float
    package var evidence: [VideoSegmentHit.Evidence]
    package var summaryText: String
    package var segments: [VideoSegmentHit]

    package init(videoID: VideoID, score: Float, evidence: [VideoSegmentHit.Evidence], summaryText: String, segments: [VideoSegmentHit]) {
        self.videoID = videoID
        self.score = score
        self.evidence = evidence
        self.summaryText = summaryText
        self.segments = segments
    }
}

/// Deterministic recall output suitable for prompting.
package struct VideoRAGContext: Sendable, Equatable {
    package struct Diagnostics: Sendable, Equatable {
        package var usedTextTokens: Int
        package var degradedVideoCount: Int

        package init(usedTextTokens: Int = 0, degradedVideoCount: Int = 0) {
            self.usedTextTokens = max(0, usedTextTokens)
            self.degradedVideoCount = max(0, degradedVideoCount)
        }
    }

    package var query: VideoQuery
    package var items: [VideoRAGItem]
    package var diagnostics: Diagnostics

    package init(query: VideoQuery, items: [VideoRAGItem], diagnostics: Diagnostics = .init()) {
        self.query = query
        self.items = items
        self.diagnostics = diagnostics
    }
}

/// Errors thrown during video ingestion.
package enum VideoIngestError: Error, Sendable, Equatable {
    case fileMissing(id: String, url: URL)
    case unsupportedPlatform(reason: String)
    case invalidVideo(reason: String)
    case embedderDimensionMismatch(expected: Int, got: Int)
}

