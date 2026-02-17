import Foundation

/// Transcript request passed to a `VideoTranscriptProvider`.
public struct VideoTranscriptRequest: Sendable, Equatable {
    /// Stable identifier for the video being transcribed.
    public var videoID: VideoID
    /// Local file URL for the video bytes.
    public var localFileURL: URL
    /// Video duration in milliseconds, if known.
    public var durationMs: Int64?

    public init(videoID: VideoID, localFileURL: URL, durationMs: Int64? = nil) {
        self.videoID = videoID
        self.localFileURL = localFileURL
        self.durationMs = durationMs
    }
}

/// A timed transcript chunk in milliseconds relative to the start of the video.
public struct VideoTranscriptChunk: Sendable, Equatable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String

    public init(startMs: Int64, endMs: Int64, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// Host-supplied transcript provider for Video RAG.
///
/// Notes:
/// - Wax does not perform transcription in v1.
/// - The host app controls transcript generation and may choose to run it fully on-device.
public protocol VideoTranscriptProvider: Sendable {
    /// Declares whether this provider may call network services.
    var executionMode: ProviderExecutionMode { get }
    /// Generate timed transcript chunks for a video.
    ///
    /// Chunks should have `startMs` and `endMs` relative to the start of the video.
    /// Wax maps chunks to segments using a 250ms overlap threshold.
    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk]
}

// MARK: - Deprecated Default (migration aid)

extension VideoTranscriptProvider {
    /// Default removed to enforce explicit execution mode declaration.
    /// Provide an explicit `executionMode` property on your conformance.
    @available(*, deprecated, message: "Provide an explicit 'executionMode' on your VideoTranscriptProvider conformance.")
    public var executionMode: ProviderExecutionMode { .onDeviceOnly }
}
