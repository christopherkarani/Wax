#if canImport(ImageIO)
import Foundation
import WaxCore
import WaxVectorSearch

/// Owning public facade for on-device photo memory.
public actor PhotoMemory {
    public typealias Error = WaxError

    /// Configuration for a ``PhotoMemory`` store.
    public struct Config: Sendable, Equatable {
        public var enableOCR: Bool
        public var enableRegionEmbeddings: Bool
        /// When true, recalled items include PNG thumbnail bytes.
        ///
        /// This flag gates pixel attachment on search hits. It is not limited to
        /// downstream LLM prompt assembly.
        public var includeThumbnailsInContext: Bool
        /// When true, recalled items include region crop bytes for matched regions.
        ///
        /// This flag gates crop attachment on search hits. It is not limited to
        /// downstream LLM prompt assembly.
        public var includeRegionCropsInContext: Bool
        public var requireOnDeviceProviders: Bool
        public var ingestConcurrency: Int
        public var embedMaxPixelSize: Int
        public var ocrMaxPixelSize: Int
        public var maxRegionsPerPhoto: Int
        public var searchTopK: Int
        public var hybridAlpha: Float
        public var lockWaitTimeout: Duration
        public var walSizeBytes: UInt64

        public init(
            enableOCR: Bool = true,
            enableRegionEmbeddings: Bool = true,
            includeThumbnailsInContext: Bool = true,
            includeRegionCropsInContext: Bool = true,
            requireOnDeviceProviders: Bool = true,
            ingestConcurrency: Int = 2,
            embedMaxPixelSize: Int = 512,
            ocrMaxPixelSize: Int = 1024,
            maxRegionsPerPhoto: Int = 8,
            searchTopK: Int = 200,
            hybridAlpha: Float = 0.5,
            lockWaitTimeout: Duration = .zero,
            walSizeBytes: UInt64 = Memory.Config.defaultWalSizeBytes
        ) {
            self.enableOCR = enableOCR
            self.enableRegionEmbeddings = enableRegionEmbeddings
            self.includeThumbnailsInContext = includeThumbnailsInContext
            self.includeRegionCropsInContext = includeRegionCropsInContext
            self.requireOnDeviceProviders = requireOnDeviceProviders
            self.ingestConcurrency = max(1, ingestConcurrency)
            self.embedMaxPixelSize = max(1, embedMaxPixelSize)
            self.ocrMaxPixelSize = max(1, ocrMaxPixelSize)
            self.maxRegionsPerPhoto = max(0, maxRegionsPerPhoto)
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

    /// A local image file to ingest.
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

    /// Search parameters for photo memory.
    public struct Query: Sendable, Equatable {
        public var text: String?
        public var resultLimit: Int
        public var timeRange: ClosedRange<Date>?
        public var imageData: Data?
        public var imageFormat: WaxImageFormat?

        public init(
            text: String? = nil,
            resultLimit: Int = 12,
            timeRange: ClosedRange<Date>? = nil,
            imageData: Data? = nil,
            imageFormat: WaxImageFormat? = nil
        ) {
            self.text = text
            self.resultLimit = max(0, resultLimit)
            self.timeRange = timeRange
            self.imageData = imageData
            self.imageFormat = imageFormat
        }
    }

    /// A matched region on a recalled photo, with an optional PNG crop.
    public struct Region: Sendable, Equatable {
        public var bbox: BoundingBox
        public var crop: Data?

        public init(bbox: BoundingBox, crop: Data? = nil) {
            self.bbox = bbox
            self.crop = crop
        }
    }

    /// One recalled photo.
    public struct Item: Sendable, Equatable {
        public var assetID: String
        public var score: Float
        public var summaryText: String
        /// PNG thumbnail bytes when ``Config/includeThumbnailsInContext`` is true
        /// and a pixel source is still available.
        public var thumbnail: Data?
        /// Matched region crops when ``Config/includeRegionCropsInContext`` is true.
        public var regions: [Region]

        public init(
            assetID: String,
            score: Float,
            summaryText: String,
            thumbnail: Data? = nil,
            regions: [Region] = []
        ) {
            self.assetID = assetID
            self.score = score
            self.summaryText = summaryText
            self.thumbnail = thumbnail
            self.regions = regions
        }
    }

    /// Ranked photo search results.
    public struct Results: Sendable, Equatable {
        public var items: [Item]
        public var usedTextTokens: Int
        public var degradedResultCount: Int

        public init(items: [Item], usedTextTokens: Int = 0, degradedResultCount: Int = 0) {
            self.items = items
            self.usedTextTokens = max(0, usedTextTokens)
            self.degradedResultCount = max(0, degradedResultCount)
        }
    }

    /// A recognized OCR span returned by ``PhotoOCRProvider``.
    public struct RecognizedText: Sendable, Equatable {
        public var text: String
        public var confidence: Float
        public var language: String?
        public var bbox: BoundingBox

        public init(
            text: String,
            confidence: Float,
            language: String? = nil,
            bbox: BoundingBox = BoundingBox(x: 0, y: 0, width: 1, height: 1)
        ) {
            self.text = text
            self.confidence = confidence
            self.language = language
            self.bbox = bbox
        }
    }

    /// Normalized rectangle in `[0, 1]` coordinates with a top-left origin.
    public struct BoundingBox: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    #if canImport(Photos)
    /// Photos-library sync scope. Does not expose Photos framework types.
    public enum LibraryScope: Sendable, Equatable {
        case fullLibrary
        case assetIDs([String])
    }
    #endif

    private let orchestrator: PhotoRAGOrchestrator

    /// Create or open a photo memory store at `url`.
    public static func open(
        at url: URL,
        embedding: any MultimodalEmbeddingProvider,
        ocr: (any PhotoOCRProvider)? = nil,
        captioner: (any PhotoCaptionProvider)? = nil,
        config: Config = .default
    ) async throws -> PhotoMemory {
        try validate(config)
        try validateProviders(
            embedding: embedding,
            ocr: ocr,
            captioner: captioner,
            requireOnDevice: config.requireOnDeviceProviders
        )
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: PhotoRAGConfig(config),
            embedder: MultimodalEmbeddingProviderAdapter(embedding),
            ocr: ocr.map(PhotoOCRProviderAdapter.init),
            captioner: captioner.map(PhotoCaptionProviderAdapter.init),
            waxOptions: WaxOptions(lockWaitTimeout: config.lockWaitTimeout),
            walSizeBytes: config.walSizeBytes
        )
        return PhotoMemory(orchestrator: orchestrator)
    }

    private init(orchestrator: PhotoRAGOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// Ingest local image files.
    public func ingest(files: [File]) async throws {
        try await orchestrator.ingest(files: files.map(PhotoFile.init))
    }

    #if canImport(Photos)
    /// Sync Photos-library images by stable asset identifier. Offline-only.
    public func syncLibrary(scope: LibraryScope) async throws {
        let mapped: PhotoScope = switch scope {
        case .fullLibrary:
            .fullLibrary
        case .assetIDs(let ids):
            .assetIDs(ids)
        }
        try await orchestrator.syncLibrary(scope: mapped)
    }
    #endif

    /// Search ingested photos.
    public func search(_ query: Query) async throws -> Results {
        let context = try await orchestrator.recall(PhotoQuery(query))
        return Results(context)
    }

    /// Delete all frames associated with `assetID`.
    public func delete(assetID: String) async throws {
        try await orchestrator.delete(assetID: assetID)
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Close the store and release the exclusive lock acquired by ``open(at:embedding:ocr:captioner:config:)``.
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
        ocr: (any PhotoOCRProvider)?,
        captioner: (any PhotoCaptionProvider)?,
        requireOnDevice: Bool
    ) throws {
        guard requireOnDevice else { return }
        if embedding.executionMode != .onDeviceOnly {
            throw WaxError.invalidConfiguration(reason: "PhotoMemory requires an on-device embedding provider")
        }
        if let ocr, ocr.executionMode != .onDeviceOnly {
            throw WaxError.invalidConfiguration(reason: "PhotoMemory requires an on-device OCR provider")
        }
        if let captioner, captioner.executionMode != .onDeviceOnly {
            throw WaxError.invalidConfiguration(reason: "PhotoMemory requires an on-device caption provider")
        }
    }
}

#endif
