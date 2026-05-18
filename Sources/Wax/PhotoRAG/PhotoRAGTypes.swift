import Foundation

/// Controls how much context is assembled for downstream models/agents.
package struct ContextBudget: Sendable, Equatable {
    package var maxTextTokens: Int
    package var maxImages: Int
    package var maxRegions: Int
    package var maxOCRLinesPerItem: Int

    package init(
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

    package static let `default` = ContextBudget()
}

/// Optional filters applied during photo recall.
package struct PhotoFilters: Sendable, Equatable {
    package var assetIDs: Set<String>?
    package var source: PhotoSource?
    package var isLocal: Bool?

    package init(
        assetIDs: Set<String>? = nil,
        source: PhotoSource? = nil,
        isLocal: Bool? = nil
    ) {
        self.assetIDs = Self.normalizedNonEmptySet(assetIDs)
        self.source = source
        self.isLocal = isLocal
    }

    package static let none = PhotoFilters()

    package var isEmpty: Bool {
        assetIDs == nil && source == nil && isLocal == nil
    }

    private static func normalizedNonEmptySet(_ values: Set<String>?) -> Set<String>? {
        guard let values else { return nil }
        let normalized = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return normalized.isEmpty ? nil : normalized
    }
}

/// Source backing a photo record in the package-only Photo RAG pipeline.
package enum PhotoSource: String, Sendable, Equatable {
    case photos
    case file
}

/// A GPS coordinate used for location-based photo queries.
package struct PhotoCoordinate: Sendable, Equatable {
    /// Latitude in degrees (-90 to 90).
    package var latitude: Double
    /// Longitude in degrees (-180 to 180).
    package var longitude: Double

    package init(latitude: Double, longitude: Double) {
        self.latitude = min(90, max(-90, latitude))
        self.longitude = min(180, max(-180, longitude))
    }
}

/// A location-radius query for finding photos near a GPS coordinate.
package struct PhotoLocationQuery: Sendable, Equatable {
    /// Center point of the search area.
    package var center: PhotoCoordinate
    /// Search radius in meters from the center point.
    package var radiusMeters: Double

    package init(center: PhotoCoordinate, radiusMeters: Double) {
        self.center = center
        self.radiusMeters = max(0, radiusMeters)
    }
}

/// Scope of a Photos library sync operation.
package enum PhotoScope: Sendable, Equatable {
    /// Sync all photos in the library.
    case fullLibrary
    /// Sync only the specified asset identifiers.
    case assetIDs([String])
}

/// A local image file to ingest into the package-only Photo RAG pipeline.
package struct PhotoFile: Sendable, Equatable {
    /// Stable caller-provided identifier used as the photo asset ID in Wax metadata.
    package var id: String
    /// Local file URL for the image bytes.
    package var url: URL
    /// Optional capture date when no image metadata timestamp is available.
    package var captureDate: Date?

    package init(id: String, url: URL, captureDate: Date? = nil) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = trimmed.isEmpty ? url.standardizedFileURL.absoluteString : trimmed
        self.url = url
        self.captureDate = captureDate
    }
}

/// Errors thrown during photo ingestion.
package enum PhotoIngestError: Error, Sendable, Equatable {
    case fileMissing(id: String, url: URL)
    case invalidImage(reason: String)
    case embedderDimensionMismatch(expected: Int, got: Int)
}

/// A Sendable wrapper for query-time images.
///
/// The framework decodes this into a `CGImage` internally for embedding.
package struct PhotoQueryImage: Sendable, Equatable {
    package enum Format: Sendable, Equatable {
        case jpeg
        case png
        case heic
        case other(uti: String)
    }

    package var data: Data
    package var format: Format

    package init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }
}

/// A Sendable wrapper for returning image pixels as part of a RAG context.
package struct PhotoPixel: Sendable, Equatable {
    package var data: Data
    package var format: PhotoQueryImage.Format
    package var width: Int
    package var height: Int

    package init(data: Data, format: PhotoQueryImage.Format, width: Int, height: Int) {
        self.data = data
        self.format = format
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// Normalized rectangle in [0, 1] coordinates with **top-left** origin.
package struct PhotoNormalizedRect: Sendable, Equatable {
    package var x: Double
    package var y: Double
    package var width: Double
    package var height: Double

    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct PhotoQuery: Sendable, Equatable {
    package var text: String?
    package var image: PhotoQueryImage?
    package var timeRange: ClosedRange<Date>?
    package var location: PhotoLocationQuery?
    package var filters: PhotoFilters
    package var resultLimit: Int
    package var contextBudget: ContextBudget

    package init(
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

package struct PhotoRAGContext: Sendable, Equatable {
    package struct Diagnostics: Sendable, Equatable {
        package var usedTextTokens: Int
        package var degradedResultCount: Int
        package var clarifyingQuestion: String?

        package init(usedTextTokens: Int = 0, degradedResultCount: Int = 0, clarifyingQuestion: String? = nil) {
            self.usedTextTokens = max(0, usedTextTokens)
            self.degradedResultCount = max(0, degradedResultCount)
            self.clarifyingQuestion = clarifyingQuestion
        }
    }

    package var query: PhotoQuery
    package var items: [PhotoRAGItem]
    package var diagnostics: Diagnostics

    package init(query: PhotoQuery, items: [PhotoRAGItem], diagnostics: Diagnostics = .init()) {
        self.query = query
        self.items = items
        self.diagnostics = diagnostics
    }
}

package struct PhotoRAGItem: Sendable, Equatable {
    package enum Evidence: Sendable, Equatable {
        case vector
        case text(snippet: String?)
        case region(bbox: PhotoNormalizedRect)
        case timeline
    }

    package struct RegionContext: Sendable, Equatable {
        package var bbox: PhotoNormalizedRect
        package var crop: PhotoPixel?

        package init(bbox: PhotoNormalizedRect, crop: PhotoPixel? = nil) {
            self.bbox = bbox
            self.crop = crop
        }
    }

    package var assetID: String
    package var score: Float
    package var evidence: [Evidence]
    package var summaryText: String
    package var thumbnail: PhotoPixel?
    package var regions: [RegionContext]

    package init(
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
