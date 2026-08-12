#if canImport(ImageIO)
import Foundation
import WaxCore
import WaxVectorSearch

/// Host-supplied transcript provider for ``VideoMemory``.
///
/// Wax does not transcribe audio. The host controls transcript generation.
public protocol VideoTranscriptProvider: Sendable {
    var executionMode: ProviderExecutionMode { get }
    func transcript(for request: VideoMemory.TranscriptRequest) async throws -> [VideoMemory.TranscriptChunk]
}

package struct VideoTranscriptProviderAdapter: VideoTranscriptPipelineProvider {
    private let wrapped: any VideoTranscriptProvider

    package init(_ wrapped: any VideoTranscriptProvider) {
        self.wrapped = wrapped
    }

    package var executionMode: ProviderExecutionMode { wrapped.executionMode }

    package func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        let publicRequest = VideoMemory.TranscriptRequest(
            videoID: VideoMemory.ID(request.videoID),
            localFileURL: request.localFileURL,
            durationMs: request.durationMs
        )
        let chunks = try await wrapped.transcript(for: publicRequest)
        return chunks.map {
            VideoTranscriptChunk(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        }
    }
}

extension VideoFile {
    init(_ file: VideoMemory.File) {
        self.init(id: file.id, url: file.url, captureDate: file.captureDate)
    }
}

extension VideoID {
    init(_ id: VideoMemory.ID) {
        let source: VideoID.Source = switch id.source {
        case .photos: .photos
        case .file: .file
        }
        self.init(source: source, id: id.id)
    }
}

extension VideoMemory.ID {
    init(_ id: VideoID) {
        let source: VideoMemory.ID.Source = switch id.source {
        case .photos: .photos
        case .file: .file
        }
        self.init(source: source, id: id.id)
    }
}

extension VideoQuery {
    init(_ query: VideoMemory.Query) {
        let allowlist = query.videoIDs?.map(VideoID.init)
        self.init(
            text: query.text,
            timeRange: query.timeRange,
            videoIDs: allowlist.map(Set.init),
            resultLimit: query.resultLimit,
            segmentLimitPerVideo: query.segmentLimitPerVideo
        )
    }
}

extension VideoMemory.Segment {
    init(_ hit: VideoSegmentHit) {
        self.init(
            startMs: hit.startMs,
            endMs: hit.endMs,
            score: hit.score,
            transcriptSnippet: hit.transcriptSnippet
        )
    }
}

extension VideoMemory.Item {
    init(_ item: VideoRAGItem) {
        self.init(
            id: VideoMemory.ID(item.videoID),
            score: item.score,
            summaryText: item.summaryText,
            segments: item.segments.map(VideoMemory.Segment.init)
        )
    }
}

extension VideoMemory.Results {
    init(_ context: VideoRAGContext) {
        self.init(
            items: context.items.map(VideoMemory.Item.init),
            usedTextTokens: context.diagnostics.usedTextTokens,
            degradedVideoCount: context.diagnostics.degradedVideoCount
        )
    }
}

extension VideoRAGConfig {
    init(_ config: VideoMemory.Config) {
        self.init(
            segmentDurationSeconds: config.segmentDurationSeconds,
            segmentOverlapSeconds: config.segmentOverlapSeconds,
            maxSegmentsPerVideo: config.maxSegmentsPerVideo,
            searchTopK: config.searchTopK,
            hybridAlpha: config.hybridAlpha,
            vectorEnginePreference: .auto,
            requireOnDeviceProviders: false,
            includeThumbnailsInContext: config.includeThumbnailsInContext
        )
    }
}

#endif
