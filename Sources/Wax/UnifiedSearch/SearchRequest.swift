import Foundation
import WaxCore
import WaxVectorSearch

/// Unified search request.
public struct SearchRequest: Sendable, Equatable {
    public var query: String?
    public var embedding: [Float]?
    public var vectorEnginePreference: VectorEnginePreference
    public var mode: SearchMode
    public var topK: Int
    public var minScore: Float?
    public var timeRange: TimeRange?
    public var frameFilter: FrameFilter?
    public var asOfMs: Int64
    public var structuredMemory: StructuredMemorySearchOptions

    public var rrfK: Int
    public var previewMaxBytes: Int
    /// Threshold for switching between lazy per-frame metadata fetches and batch prefetch.
    /// Default: 50.
    public var metadataLoadingThreshold: Int
    public var allowTimelineFallback: Bool
    public var timelineFallbackLimit: Int

    public init(
        query: String? = nil,
        embedding: [Float]? = nil,
        vectorEnginePreference: VectorEnginePreference = .auto,
        mode: SearchMode = .textOnly,
        topK: Int = 10,
        minScore: Float? = nil,
        timeRange: TimeRange? = nil,
        frameFilter: FrameFilter? = nil,
        asOfMs: Int64 = Int64.max,
        structuredMemory: StructuredMemorySearchOptions = .init(),
        rrfK: Int = 60,
        previewMaxBytes: Int = 512,
        metadataLoadingThreshold: Int = 50,
        allowTimelineFallback: Bool = false,
        timelineFallbackLimit: Int = 10
    ) {
        self.query = query
        self.embedding = embedding
        self.vectorEnginePreference = vectorEnginePreference
        self.mode = mode
        self.topK = topK
        self.minScore = minScore
        self.timeRange = timeRange
        self.frameFilter = frameFilter
        self.asOfMs = asOfMs
        self.structuredMemory = structuredMemory
        self.rrfK = rrfK
        self.previewMaxBytes = previewMaxBytes
        self.metadataLoadingThreshold = metadataLoadingThreshold
        self.allowTimelineFallback = allowTimelineFallback
        self.timelineFallbackLimit = timelineFallbackLimit
    }
}

/// Structured memory lane options for unified search.
public struct StructuredMemorySearchOptions: Sendable, Equatable {
    public var weight: Float
    public var maxEntityCandidates: Int
    public var maxFacts: Int
    public var maxEvidenceFrames: Int
    public var requireEvidenceSpan: Bool

    public init(
        weight: Float = 0.2,
        maxEntityCandidates: Int = 16,
        maxFacts: Int = 64,
        maxEvidenceFrames: Int = 32,
        requireEvidenceSpan: Bool = false
    ) {
        self.weight = weight
        self.maxEntityCandidates = maxEntityCandidates
        self.maxFacts = maxFacts
        self.maxEvidenceFrames = maxEvidenceFrames
        self.requireEvidenceSpan = requireEvidenceSpan
    }
}

/// Time range filter.
public struct TimeRange: Sendable, Equatable {
    public var after: Int64?
    public var before: Int64?

    public init(after: Int64? = nil, before: Int64? = nil) {
        self.after = after
        self.before = before
    }

    public func contains(_ timestamp: Int64) -> Bool {
        if let after, timestamp < after { return false }
        if let before, timestamp >= before { return false }
        return true
    }
}

/// Frame filter predicate.
public struct FrameFilter: Sendable, Equatable {
    public var includeDeleted: Bool
    public var includeSuperseded: Bool
    public var includeSurrogates: Bool
    public var frameIds: Set<UInt64>?
    public var metadataFilter: MetadataFilter?

    public init(
        includeDeleted: Bool = false,
        includeSuperseded: Bool = false,
        includeSurrogates: Bool = false,
        frameIds: Set<UInt64>? = nil,
        metadataFilter: MetadataFilter? = nil
    ) {
        self.includeDeleted = includeDeleted
        self.includeSuperseded = includeSuperseded
        self.includeSurrogates = includeSurrogates
        self.frameIds = frameIds
        self.metadataFilter = metadataFilter
    }
}

/// Metadata predicate applied to candidate frame metadata during unified search.
public struct MetadataFilter: Sendable, Equatable {
    public var requiredEntries: [String: String]
    public var requiredTags: [TagPair]
    public var requiredLabels: [String]

    public init(
        requiredEntries: [String: String] = [:],
        requiredTags: [TagPair] = [],
        requiredLabels: [String] = []
    ) {
        self.requiredEntries = requiredEntries
        self.requiredTags = requiredTags
        self.requiredLabels = requiredLabels
    }
}
