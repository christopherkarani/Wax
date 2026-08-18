#if canImport(ImageIO)
import Foundation

/// Public facade for on-device video retrieval-augmented generation.
///
/// `VideoMemory` is the supported public entry point over the package-scoped
/// `VideoRAGOrchestrator`. It segments videos into time windows, computes keyframe
/// embeddings, optionally indexes host-supplied transcripts, and serves ranked
/// segment recall with timestamps and optional thumbnails.
///
/// The pipeline is experimental: the facade API is intentionally small, and the
/// underlying orchestrator remains package-scoped.
///
/// ```swift
/// let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
/// let videos = try await VideoMemory(
///     at: storeURL,
///     embedder: embedder,
///     transcriptProvider: myTranscriptProvider
/// )
/// try await videos.ingest(files: [VideoFile(id: "standup", url: movieURL)])
/// let context = try await videos.recall(VideoQuery(text: "sprint retro action items"))
/// try await videos.close()
/// ```
public actor VideoMemory {
    private let orchestrator: VideoRAGOrchestrator
    private var isClosed = false

    /// Create or open a video memory store at the given URL.
    ///
    /// - Parameters:
    ///   - url: Store location on disk. Created if missing.
    ///   - config: Segmentation, embedding, transcript, and search tuning.
    ///   - embedder: Multimodal embedding provider shared by keyframe and text lanes.
    ///   - transcriptProvider: Optional host-supplied transcript provider.
    public init(
        at url: URL,
        config: VideoRAGConfig = .default,
        embedder: any MultimodalEmbeddingProvider,
        transcriptProvider: (any VideoTranscriptProvider)? = nil
    ) async throws {
        orchestrator = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: embedder,
            transcriptProvider: transcriptProvider
        )
    }

    #if canImport(Photos)
    /// Sync videos from the Photos library into the store.
    ///
    /// Requires Photos authorization.
    public func syncLibrary(scope: VideoScope) async throws {
        try await orchestrator.syncLibrary(scope: scope)
    }
    #endif

    /// Ingest local video files.
    public func ingest(files: [VideoFile]) async throws {
        try await orchestrator.ingest(files: files)
    }

    /// Recall ranked video context for a query.
    public func recall(_ query: VideoQuery) async throws -> VideoRAGContext {
        try await orchestrator.recall(query)
    }

    /// Delete a video root and all segment frames plus vectors.
    public func delete(videoID: VideoID) async throws {
        try await orchestrator.delete(videoID: videoID)
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Flush pending writes and close the store. Safe to call more than once.
    public func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        try await orchestrator.close()
    }
}
#endif // canImport(ImageIO)
