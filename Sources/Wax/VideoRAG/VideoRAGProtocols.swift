@_exported import CoreGraphics
import Foundation
import WaxVectorSearch

/// A host-supplied multimodal embedding provider for Video RAG.
///
/// Requirements:
/// - `embed(text:)` and `embed(image:)` must return vectors in the same embedding space.
/// - If `normalize == true`, Wax will L2-normalize embeddings before storage/search.
public protocol MultimodalEmbeddingProvider: Sendable {
    /// Dimensionality of all embeddings produced by this provider.
    var dimensions: Int { get }
    /// Whether embeddings are expected to be L2-normalized.
    var normalize: Bool { get }
    /// Optional identity metadata to stamp into Wax frame metadata at write time.
    var identity: EmbeddingIdentity? { get }

    /// Compute a text embedding in the same space as image embeddings.
    func embed(text: String) async throws -> [Float]
    /// Compute an image embedding in the same space as text embeddings.
    func embed(image: CGImage) async throws -> [Float]
}

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
    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk]
}
