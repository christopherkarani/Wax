#if canImport(ImageIO)
import Foundation
import WaxCore
import WaxVectorSearch

/// Owning public facade for on-device video memory.
public actor VideoMemory {
    public typealias Error = WaxError

    /// Configuration for a ``VideoMemory`` store.
    public struct Config: Sendable, Equatable {
        public var segmentDurationSeconds: Double
        public var segmentOverlapSeconds: Double
        public var maxSegmentsPerVideo: Int
        /// When true, recalled segments include PNG keyframe thumbnail bytes.
        ///
        /// This flag gates pixel attachment on search hits. It is not limited to
        /// downstream LLM prompt assembly. Public search requests a thumbnail
        /// budget automatically; the orchestrator still no-ops when this flag is false.
        public var includeThumbnailsInContext: Bool
        public var requireOnDeviceProviders: Bool
        public var searchTopK: Int
        public var hybridAlpha: Float
        public var lockWaitTimeout: Duration
        public var walSizeBytes: UInt64

        public init(
            segmentDurationSeconds: Double = 10,
            segmentOverlapSeconds: Double = 0,
            maxSegmentsPerVideo: Int = 360,
            includeThumbnailsInContext: Bool = false,
            requireOnDeviceProviders: Bool = true,
            searchTopK: Int = 400,
            hybridAlpha: Float = 0.5,
            lockWaitTimeout: Duration = .zero,
            walSizeBytes: UInt64 = Memory.Config.defaultWalSizeBytes
        ) {
            self.segmentDurationSeconds = max(0, segmentDurationSeconds)
            self.segmentOverlapSeconds = max(0, segmentOverlapSeconds)
            self.maxSegmentsPerVideo = max(0, maxSegmentsPerVideo)
            self.includeThumbnailsInContext = includeThumbnailsInContext
            self.requireOnDeviceProviders = requireOnDeviceProviders
            self.searchTopK = max(0, searchTopK)
            self.hybridAlpha = Self.clamp01(hybridAlpha)
            self.lockWaitTimeout = lockWaitTimeout
            self.walSizeBytes = walSizeBytes
        }

        public static let `default` = Config()

        @inline(__always)
        private static func clamp01(_ value: Float) -> Float {
            if value == .infinity { return 1 }
            if value == -.infinity { return 0 }
            guard value.isFinite else { return 0.5 }
            return min(1, max(0, value))
        }
    }

    /// Stable identifier for a stored video.
    public struct ID: Sendable, Hashable, Equatable {
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

    /// A local video file to ingest.
    public struct File: Sendable, Equatable {
        public var id: String
        public var url: URL
        public var captureDate: Date?

        public init(id: String, url: URL, captureDate: Date? = nil) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            self.id = trimmed.isEmpty ? url.standardizedFileURL.absoluteString : trimmed
            self.url = url
            self.captureDate = captureDate
        }
    }

    /// Search parameters for video memory.
    public struct Query: Sendable, Equatable {
        public var text: String?
        public var resultLimit: Int
        public var segmentLimitPerVideo: Int
        public var timeRange: ClosedRange<Date>?
        public var videoIDs: Set<ID>?

        public init(
            text: String? = nil,
            resultLimit: Int = 12,
            segmentLimitPerVideo: Int = 3,
            timeRange: ClosedRange<Date>? = nil,
            videoIDs: Set<ID>? = nil
        ) {
            self.text = text
            self.resultLimit = max(0, resultLimit)
            self.segmentLimitPerVideo = max(0, segmentLimitPerVideo)
            self.timeRange = timeRange
            self.videoIDs = videoIDs
        }
    }

    /// One recalled video segment.
    public struct Segment: Sendable, Equatable {
        public var startMs: Int64
        public var endMs: Int64
        public var score: Float
        public var transcriptSnippet: String?
        /// PNG keyframe bytes when ``Config/includeThumbnailsInContext`` is true
        /// and a file-backed pixel source is still available.
        public var thumbnail: Data?

        public init(
            startMs: Int64,
            endMs: Int64,
            score: Float,
            transcriptSnippet: String? = nil,
            thumbnail: Data? = nil
        ) {
            self.startMs = startMs
            self.endMs = endMs
            self.score = score
            self.transcriptSnippet = transcriptSnippet
            self.thumbnail = thumbnail
        }
    }

    /// One recalled video.
    public struct Item: Sendable, Equatable {
        public var id: ID
        public var score: Float
        public var summaryText: String
        public var segments: [Segment]

        public init(id: ID, score: Float, summaryText: String, segments: [Segment] = []) {
            self.id = id
            self.score = score
            self.summaryText = summaryText
            self.segments = segments
        }
    }

    /// Ranked video search results.
    public struct Results: Sendable, Equatable {
        public var items: [Item]
        public var usedTextTokens: Int
        public var degradedVideoCount: Int

        public init(items: [Item], usedTextTokens: Int = 0, degradedVideoCount: Int = 0) {
            self.items = items
            self.usedTextTokens = max(0, usedTextTokens)
            self.degradedVideoCount = max(0, degradedVideoCount)
        }
    }

    /// Request passed to ``VideoTranscriptProvider``.
    public struct TranscriptRequest: Sendable, Equatable {
        public var videoID: ID
        public var localFileURL: URL
        public var durationMs: Int64?

        public init(videoID: ID, localFileURL: URL, durationMs: Int64? = nil) {
            self.videoID = videoID
            self.localFileURL = localFileURL
            self.durationMs = durationMs
        }
    }

    /// A timed transcript chunk relative to the start of the video.
    public struct TranscriptChunk: Sendable, Equatable {
        public var startMs: Int64
        public var endMs: Int64
        public var text: String

        public init(startMs: Int64, endMs: Int64, text: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
        }
    }

    #if canImport(Photos)
    /// Photos-library video sync scope. Does not expose Photos framework types.
    public enum LibraryScope: Sendable, Equatable {
        case fullLibrary
        case assetIDs([String])
    }
    #endif

    private let orchestrator: VideoRAGOrchestrator

    /// Create or open a video memory store at `url`.
    public static func open(
        at url: URL,
        embedding: any MultimodalEmbeddingProvider,
        transcriptProvider: (any VideoTranscriptProvider)? = nil,
        config: Config = .default
    ) async throws -> VideoMemory {
        try await open(
            at: url,
            embedding: embedding,
            transcriptProvider: transcriptProvider,
            keyframeProvider: nil,
            config: config
        )
    }

    /// Package hook for codec-independent tests that inject keyframes.
    package static func open(
        at url: URL,
        embedding: any MultimodalEmbeddingProvider,
        transcriptProvider: (any VideoTranscriptProvider)? = nil,
        keyframeProvider: (any VideoKeyframePipelineProvider)?,
        config: Config = .default
    ) async throws -> VideoMemory {
        try validate(config)
        try validateProviders(
            embedding: embedding,
            transcriptProvider: transcriptProvider,
            requireOnDevice: config.requireOnDeviceProviders
        )
        let orchestrator = try await VideoRAGOrchestrator(
            storeURL: url,
            config: VideoRAGConfig(config),
            embedder: MultimodalEmbeddingProviderAdapter(embedding),
            transcriptProvider: transcriptProvider.map(VideoTranscriptProviderAdapter.init),
            keyframeProvider: keyframeProvider,
            waxOptions: WaxOptions(lockWaitTimeout: config.lockWaitTimeout),
            walSizeBytes: config.walSizeBytes
        )
        return VideoMemory(orchestrator: orchestrator)
    }

    private init(orchestrator: VideoRAGOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// Ingest local video files.
    public func ingest(files: [File]) async throws {
        try await orchestrator.ingest(files: files.map(VideoFile.init))
    }

    #if canImport(Photos)
    /// Sync Photos-library videos by stable asset identifier. Offline-only.
    public func syncLibrary(scope: LibraryScope) async throws {
        let mapped: VideoRAGOrchestrator.VideoScope = switch scope {
        case .fullLibrary:
            .fullLibrary
        case .assetIDs(let ids):
            .assetIDs(ids)
        }
        try await orchestrator.syncLibrary(scope: mapped)
    }
    #endif

    /// Search ingested videos.
    public func search(_ query: Query) async throws -> Results {
        let context = try await orchestrator.recall(VideoQuery(query))
        return Results(context)
    }

    /// Delete all frames associated with `videoID`.
    public func delete(videoID: ID) async throws {
        try await orchestrator.delete(videoID: VideoID(videoID))
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Close the store and release the exclusive lock acquired by ``open(at:embedding:transcriptProvider:config:)``.
    public func close() async throws {
        try await orchestrator.close()
    }

    private static func validate(_ config: Config) throws {
        guard config.walSizeBytes >= Constants.walRecordHeaderSize else {
            throw WaxError.invalidConfiguration(
                reason: "WAL size must be at least \(Constants.walRecordHeaderSize) bytes (WAL record header); got \(config.walSizeBytes)"
            )
        }
    }

    private static func validateProviders(
        embedding: any MultimodalEmbeddingProvider,
        transcriptProvider: (any VideoTranscriptProvider)?,
        requireOnDevice: Bool
    ) throws {
        guard requireOnDevice else { return }
        if embedding.executionMode != .onDeviceOnly {
            throw WaxError.invalidConfiguration(reason: "VideoMemory requires an on-device embedding provider")
        }
        if let transcriptProvider, transcriptProvider.executionMode != .onDeviceOnly {
            throw WaxError.invalidConfiguration(reason: "VideoMemory requires an on-device transcript provider")
        }
    }
}

#endif
