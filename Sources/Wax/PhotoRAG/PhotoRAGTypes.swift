import Foundation

/// Controls how much context is assembled for downstream models/agents.
public struct ContextBudget: Sendable, Equatable {
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

    public static let `default` = ContextBudget()
}

/// Optional filters applied during photo recall.
public struct PhotoFilters: Sendable, Equatable {
    public init() {}

    public static let none = PhotoFilters()
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
    /// Sync only the specified asset identifiers.
    case assetIDs([String])
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

public struct PhotoQuery: Sendable, Equatable {
    public var text: String?
    public var image: PhotoQueryImage?
    public var timeRange: ClosedRange<Date>?
    public var location: PhotoLocationQuery?
    public var filters: PhotoFilters
    public var resultLimit: Int
    public var contextBudget: ContextBudget

    public init(
        text: String? = nil,
        image: PhotoQueryImage? = nil,
        timeRange: ClosedRange<Date>? = nil,
        location: PhotoLocationQuery? = nil,
        filters: PhotoFilters = .none,
        resultLimit: Int = 12,
        contextBudget: ContextBudget = .default
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

    public var assetID: String
    public var score: Float
    public var evidence: [Evidence]
    public var summaryText: String
    public var thumbnail: PhotoPixel?
    public var regions: [RegionContext]

    public init(
        assetID: String,
        score: Float,
        evidence: [Evidence],
        summaryText: String,
        thumbnail: PhotoPixel? = nil,
        regions: [RegionContext] = []
    ) {
        self.assetID = assetID
        self.score = score
        self.evidence = evidence
        self.summaryText = summaryText
        self.thumbnail = thumbnail
        self.regions = regions
    }
}

