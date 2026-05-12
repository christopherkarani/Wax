import Foundation
import WaxCore
import WaxVectorSearch

/// Unified search request.
package struct SearchRequest: Sendable, Equatable {
    package var query: String?
    package var embedding: [Float]?
    package var vectorEnginePreference: VectorEnginePreference
    package var vectorSearchTimeout: Duration?
    package var mode: SearchMode
    package var topK: Int
    package var minScore: Float?
    package var timeRange: SearchTimeRange?
    package var frameFilter: FrameFilter?
    package var asOfMs: Int64
    package var structuredMemory: StructuredMemorySearchOptions
    package var scopeContext: MemoryScopeContext?

    package var rrfK: Int
    package var previewMaxBytes: Int
    /// Threshold for switching between lazy per-frame metadata fetches and batch prefetch.
    /// Default: 50.
    package var metadataLoadingThreshold: Int
    package var allowTimelineFallback: Bool
    package var timelineFallbackLimit: Int
    package var enableRankingDiagnostics: Bool
    package var rankingDiagnosticsTopK: Int

    package init(
        query: String? = nil,
        embedding: [Float]? = nil,
        vectorEnginePreference: VectorEnginePreference = .auto,
        vectorSearchTimeout: Duration? = .seconds(10),
        mode: SearchMode = .textOnly,
        topK: Int = 10,
        minScore: Float? = nil,
        timeRange: SearchTimeRange? = nil,
        frameFilter: FrameFilter? = nil,
        asOfMs: Int64 = Int64.max,
        structuredMemory: StructuredMemorySearchOptions = .init(),
        scopeContext: MemoryScopeContext? = nil,
        rrfK: Int = 60,
        previewMaxBytes: Int = 512,
        metadataLoadingThreshold: Int = 50,
        allowTimelineFallback: Bool = false,
        timelineFallbackLimit: Int = 10,
        enableRankingDiagnostics: Bool = false,
        rankingDiagnosticsTopK: Int = 10
    ) {
        self.query = query
        self.embedding = embedding
        self.vectorEnginePreference = vectorEnginePreference
        self.vectorSearchTimeout = vectorSearchTimeout
        self.mode = mode
        self.topK = topK
        self.minScore = minScore
        self.timeRange = timeRange
        self.frameFilter = frameFilter
        self.asOfMs = asOfMs
        self.structuredMemory = structuredMemory
        self.scopeContext = scopeContext
        self.rrfK = rrfK
        self.previewMaxBytes = previewMaxBytes
        self.metadataLoadingThreshold = metadataLoadingThreshold
        self.allowTimelineFallback = allowTimelineFallback
        self.timelineFallbackLimit = timelineFallbackLimit
        self.enableRankingDiagnostics = enableRankingDiagnostics
        self.rankingDiagnosticsTopK = rankingDiagnosticsTopK
    }
}

/// Structured memory lane options for unified search.
package struct StructuredMemorySearchOptions: Sendable, Equatable {
    package var weight: Float
    package var maxEntityCandidates: Int
    package var maxFacts: Int
    package var maxEvidenceFrames: Int
    package var requireEvidenceSpan: Bool

    package init(
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
package struct SearchTimeRange: Sendable, Equatable {
    package var after: Int64?
    package var before: Int64?

    package init(after: Int64? = nil, before: Int64? = nil) {
        self.after = after
        self.before = before
    }

    package func contains(_ timestamp: Int64) -> Bool {
        if let after, timestamp < after { return false }
        if let before, timestamp >= before { return false }
        return true
    }
}

/// Frame filter predicate.
package struct FrameFilter: Sendable, Equatable {
    package var includeDeleted: Bool
    package var includeSuperseded: Bool
    package var includeSurrogates: Bool
    package var frameIds: Set<UInt64>?
    package var metadataFilter: MetadataFilter?

    package init(
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
package struct MetadataFilter: Sendable, Equatable {
    package var requiredEntries: [String: String]
    package var requiredTags: [TagPair]
    package var requiredLabels: [String]

    package init(
        requiredEntries: [String: String] = [:],
        requiredTags: [TagPair] = [],
        requiredLabels: [String] = []
    ) {
        self.requiredEntries = requiredEntries
        self.requiredTags = requiredTags
        self.requiredLabels = requiredLabels
    }
}
