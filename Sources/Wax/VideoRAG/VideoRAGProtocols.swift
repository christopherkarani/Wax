import Foundation

/// Transcript request passed to a `VideoTranscriptProvider`.
package struct VideoTranscriptRequest: Sendable, Equatable {
    /// Stable identifier for the video being transcribed.
    package var videoID: VideoID
    /// Local file URL for the video bytes.
    package var localFileURL: URL
    /// Video duration in milliseconds, if known.
    package var durationMs: Int64?

    package init(videoID: VideoID, localFileURL: URL, durationMs: Int64? = nil) {
        self.videoID = videoID
        self.localFileURL = localFileURL
        self.durationMs = durationMs
    }
}

/// A timed transcript chunk in milliseconds relative to the start of the video.
package struct VideoTranscriptChunk: Sendable, Equatable {
    package var startMs: Int64
    package var endMs: Int64
    package var text: String

    package init(startMs: Int64, endMs: Int64, text: String) {
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
package protocol VideoTranscriptProvider: Sendable {
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
    package var executionMode: ProviderExecutionMode { .onDeviceOnly }
}
