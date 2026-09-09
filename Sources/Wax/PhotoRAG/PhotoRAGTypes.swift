import Foundation

/// Stable, type-safe identifier for a photo across Photos library and file ingest.
public struct PhotoID: Sendable, Hashable, Equatable {
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

    /// Wire value stored in `photo.source`. Persistence stays a string.
    package var metadataSource: String {
        switch source {
        case .photos: PhotoSource.photos.rawValue
        case .file: PhotoSource.file.rawValue
        }
    }

    /// Reconstruct from on-disk metadata. Missing/unknown `photo.source` is `.photos`
    /// (legacy Photos ingest omitted the key; file ingest always writes `file`).
    package static func fromMetadata(id: String, source: String?) -> PhotoID? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed: Source = (source == PhotoSource.file.rawValue) ? .file : .photos
        return PhotoID(source: parsed, id: trimmed)
    }
}

/// Token and image limits for assembled ``PhotoMemory`` recall context.
public struct PhotoContextBudget: Sendable, Equatable {
    public var maxTextTokens: Int
    public var maxImages: Int
    public var maxRegions: Int
    public var maxOCRLinesPerItem: Int

    public init(
        maxTextTokens: Int = 1_200,
        maxImages: Int = 6,
        maxRegions: Int = 8,
        maxOCRLinesPerItem: Int = 8
    ) {
        self.maxTextTokens = max(0, maxTextTokens)
        self.maxImages = max(0, maxImages)
        self.maxRegions = max(0, maxRegions)
        self.maxOCRLinesPerItem = max(0, maxOCRLinesPerItem)
    }

    public static let `default` = PhotoContextBudget()
}

/// Optional filters applied during photo recall.
public struct PhotoFilters: Sendable, Equatable {
    public var assetIDs: Set<PhotoID>?
    public var source: PhotoSource?
    public var isLocal: Bool?

    public init(
        assetIDs: Set<PhotoID>? = nil,
        source: PhotoSource? = nil,
        isLocal: Bool? = nil
    ) {
        self.assetIDs = Self.normalizedNonEmptySet(assetIDs)
        self.source = source
        self.isLocal = isLocal
    }

    public static let none = PhotoFilters()

    public var isEmpty: Bool {
        assetIDs == nil && source == nil && isLocal == nil
    }

    private static func normalizedNonEmptySet(_ values: Set<PhotoID>?) -> Set<PhotoID>? {
        guard let values else { return nil }
        var normalized: Set<PhotoID> = []
        normalized.reserveCapacity(values.count)
        for photoID in values {
            guard let parsed = PhotoID.fromMetadata(id: photoID.id, source: photoID.metadataSource) else {
                continue
            }
            normalized.insert(parsed)
        }
        return normalized.isEmpty ? nil : normalized
    }
}

/// Source backing a photo record ingested by ``PhotoMemory``.
public enum PhotoSource: String, Sendable, Equatable {
    case photos
    case file
}

/// A GPS coordinate used for location-based photo queries.
public struct PhotoCoordinate: Sendable, Equatable {
    /// Latitude in degrees (-90 to 90).
    public var latitude: Double
    /// Longitude in degrees (-180 to 180).
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = min(90, max(-90, latitude))
        self.longitude = min(180, max(-180, longitude))
    }
}

/// A location-radius query for finding photos near a GPS coordinate.
public struct PhotoLocationQuery: Sendable, Equatable {
    /// Center point of the search area.
    public var center: PhotoCoordinate
    /// Search radius in meters from the center point.
    public var radiusMeters: Double

    public init(center: PhotoCoordinate, radiusMeters: Double) {
        self.center = center
        self.radiusMeters = max(0, radiusMeters)
    }
}

/// Scope of a Photos library sync operation.
public enum PhotoScope: Sendable, Equatable {
    /// Sync all photos in the library.
    case fullLibrary
    /// Sync only the specified photo identifiers.
    case assetIDs([PhotoID])
}

/// A local image file to ingest into ``PhotoMemory``.
public struct PhotoFile: Sendable, Equatable {
    /// Stable caller-provided identity stored as `photos.asset_id` + `photo.source`.
    public var id: PhotoID
    /// Local file URL for the image bytes.
    public var url: URL
    /// Optional capture date when no image metadata timestamp is available.
    public var captureDate: Date?

    public init(id: PhotoID, url: URL, captureDate: Date? = nil) {
        let trimmed = id.id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = PhotoID(
            source: id.source,
            id: trimmed.isEmpty ? url.standardizedFileURL.absoluteString : trimmed
        )
        self.url = url
        self.captureDate = captureDate
    }

    /// File-ingest convenience. Wraps `id` as ``PhotoID`` with `source: .file`.
    public init(id: String, url: URL, captureDate: Date? = nil) {
        self.init(id: PhotoID(source: .file, id: id), url: url, captureDate: captureDate)
    }
}

/// Errors thrown during photo ingestion.
public enum PhotoIngestError: Error, Sendable, Equatable {
    case fileMissing(id: String, url: URL)
    case invalidImage(reason: String)
    case embedderDimensionMismatch(expected: Int, got: Int)
}

/// A Sendable wrapper for query-time images.
///
/// The framework decodes this into a `CGImage` internally for embedding.
public struct PhotoQueryImage: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        case jpeg
        case png
        case heic
        case other(uti: String)
    }

    public var data: Data
    public var format: Format

    public init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }
}

/// A Sendable wrapper for returning image pixels as part of a RAG context.
public struct PhotoPixel: Sendable, Equatable {
    public var data: Data
    public var format: PhotoQueryImage.Format
    public var width: Int
    public var height: Int

    public init(data: Data, format: PhotoQueryImage.Format, width: Int, height: Int) {
        self.data = data
        self.format = format
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// Normalized rectangle in [0, 1] coordinates with **top-left** origin.
public struct PhotoNormalizedRect: Sendable, Equatable {
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

/// A photo recall query with optional text, image, time, location, and result-budget constraints.
public struct PhotoQuery: Sendable, Equatable {
    public var text: String?
    public var image: PhotoQueryImage?
    public var timeRange: ClosedRange<Date>?
    public var location: PhotoLocationQuery?
    public var filters: PhotoFilters
    public var resultLimit: Int
    public var contextBudget: PhotoContextBudget

    public init(
        text: String? = nil,
        image: PhotoQueryImage? = nil,
        timeRange: ClosedRange<Date>? = nil,
        location: PhotoLocationQuery? = nil,
        filters: PhotoFilters = .none,
        resultLimit: Int = 12,
        contextBudget: PhotoContextBudget = .default
    ) {
        self.text = text
        self.image = image
        self.timeRange = timeRange
        self.location = location
        self.filters = filters
        self.resultLimit = max(0, resultLimit)
        self.contextBudget = contextBudget
    }
}

/// Ranked photo recall result assembled for a ``PhotoQuery``.
public struct PhotoRAGContext: Sendable, Equatable {
    public struct Diagnostics: Sendable, Equatable {
        public var usedTextTokens: Int
        public var degradedResultCount: Int
        public var clarifyingQuestion: String?

        public init(usedTextTokens: Int = 0, degradedResultCount: Int = 0, clarifyingQuestion: String? = nil) {
            self.usedTextTokens = max(0, usedTextTokens)
            self.degradedResultCount = max(0, degradedResultCount)
            self.clarifyingQuestion = clarifyingQuestion
        }
    }

    public var query: PhotoQuery
    public var items: [PhotoRAGItem]
    public var diagnostics: Diagnostics

    public init(query: PhotoQuery, items: [PhotoRAGItem], diagnostics: Diagnostics = .init()) {
        self.query = query
        self.items = items
        self.diagnostics = diagnostics
    }
}

/// A single ranked photo hit in a ``PhotoRAGContext``.
public struct PhotoRAGItem: Sendable, Equatable {
    public enum Evidence: Sendable, Equatable {
        case vector
        case text(snippet: String?)
        case region(bbox: PhotoNormalizedRect)
        case timeline
    }

    public struct RegionContext: Sendable, Equatable {
        public var bbox: PhotoNormalizedRect
        public var crop: PhotoPixel?

        public init(bbox: PhotoNormalizedRect, crop: PhotoPixel? = nil) {
            self.bbox = bbox
            self.crop = crop
        }
    }

    public var photoID: PhotoID
    public var score: Float
    public var evidence: [Evidence]
    public var summaryText: String
    public var thumbnail: PhotoPixel?
    public var regions: [RegionContext]

    public init(
        photoID: PhotoID,
        score: Float,
        evidence: [Evidence],
        summaryText: String,
        thumbnail: PhotoPixel? = nil,
        regions: [RegionContext] = []
    ) {
        self.photoID = photoID
        self.score = score
        self.evidence = evidence
        self.summaryText = summaryText
        self.thumbnail = thumbnail
        self.regions = regions
    }
}
