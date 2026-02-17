import Foundation

public enum VideoMetadataKey: String, Sendable, CaseIterable {
    case source = "video.source"
    case sourceID = "video.source_id"
    case fileURL = "video.file_url"
    case captureMs = "video.capture_ms"
    case durationMs = "video.duration_ms"
    case isLocal = "video.availability.local"
    case pipelineVersion = "video.pipeline.version"

    case segmentIndex = "video.segment.index"
    case segmentCount = "video.segment.count"
    case segmentStartMs = "video.segment.start_ms"
    case segmentEndMs = "video.segment.end_ms"
    case segmentMidMs = "video.segment.mid_ms"
}
