import Foundation
import WaxCore
import WaxVectorSearch

/// Retrieval lane paired with the query embedding that lane needs.
///
/// `vectorOnly` without a non-empty embedding is rejected by ``from(mode:embedding:)``
/// and by the throwing `SearchRequest` factory. The source-compatible `mode` +
/// `embedding` initializer maps that case to `textOnly` instead of storing an
/// empty vector-only lane. Hybrid with a missing or empty embedding is stored
/// as `nil` (text degradation).
package enum SearchLane: Sendable, Equatable {
    /// Full-text retrieval only.
    case textOnly
    /// Vector-index retrieval. Must be non-empty when stored on a `SearchRequest`.
    case vectorOnly(embedding: [Float])
    /// Blend text and vector. Empty embeddings are stored as `nil`.
    case hybrid(alpha: Float = 0.5, embedding: [Float]?)

    /// Message for ``WaxError/io(_:)`` when `vectorOnly` lacks a non-empty embedding.
    package static let missingVectorOnlyEmbeddingMessage =
        "vectorOnly search requires a non-empty query embedding"

    /// Public ``SearchMode`` this lane maps to.
    package var mode: SearchMode {
        switch self {
        case .textOnly: .textOnly
        case .vectorOnly: .vectorOnly
        case .hybrid(let alpha, _): .hybrid(alpha: alpha)
        }
    }

    /// Query embedding carried by this lane, if any.
    package var embedding: [Float]? {
        switch self {
        case .textOnly:
            nil
        case .vectorOnly(let embedding):
            embedding
        case .hybrid(_, let embedding):
            embedding
        }
    }

    /// Whether this lane carries a non-empty query embedding.
    package var hasNonEmptyEmbedding: Bool {
        switch self {
        case .textOnly:
            false
        case .vectorOnly(let embedding):
            !embedding.isEmpty
        case .hybrid(_, let embedding):
            embedding.map { !$0.isEmpty } ?? false
        }
    }

    /// Maps public ``SearchMode`` × embedding availability onto a lane.
    /// Throws ``WaxError/io(_:)`` when `vectorOnly` has a missing or empty embedding.
    package static func from(mode: SearchMode, embedding: [Float]?) throws -> SearchLane {
        switch mode {
        case .textOnly:
            return .textOnly
        case .vectorOnly:
            guard let embedding, !embedding.isEmpty else {
                throw WaxError.io(missingVectorOnlyEmbeddingMessage)
            }
            return .vectorOnly(embedding: embedding)
        case .hybrid(let alpha):
            let value: [Float]?
            if let embedding, !embedding.isEmpty {
                value = embedding
            } else {
                value = nil
            }
            return .hybrid(alpha: alpha, embedding: value)
        }
    }

    /// Source-compatible mapping used by the non-throwing `mode` + `embedding`
    /// initializer. `vectorOnly` without a non-empty embedding becomes `textOnly`
    /// so that illegal empty vector-only state is never stored.
    fileprivate static func compatible(mode: SearchMode, embedding: [Float]?) -> SearchLane {
        do {
            return try from(mode: mode, embedding: embedding)
        } catch {
            return .textOnly
        }
    }
}

/// Unified search request.
package struct SearchRequest: Sendable, Equatable {
    package var query: String?
    /// Canonical retrieval lane stored by this request.
    package let lane: SearchLane
    package var vectorEnginePreference: VectorEnginePreference
    package var vectorSearchTimeout: Duration?
    package var topK: Int
    package var minScore: Float?
    package var timeRange: SearchTimeRange?
    package var frameFilter: FrameFilter?
    package var asOfMs: Int64
    /// Evaluation time for semantic recency, expiry, and ranking explanations.
    /// Distinct from `asOfMs` (structured-fact visibility cutoff).
    package var nowMs: Int64
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

    /// Diagnostics / fusion view of the stored lane. Not an independent stored field.
    package var mode: SearchMode { lane.mode }

    /// Query embedding carried by the stored lane, if any.
    package var embedding: [Float]? { lane.embedding }

    /// Creates a unified search request for `lane`.
    ///
    /// Canonicalizes `lane` through ``SearchLane/from(mode:embedding:)`` so hybrid
    /// empty embeddings become `nil` and `vectorOnly` without a non-empty
    /// embedding is rejected.
    ///
    /// - Throws: ``WaxError/io(_:)`` when `lane` is `vectorOnly` with a missing
    ///   or empty embedding.
    package init(
        query: String? = nil,
        lane: SearchLane,
        vectorEnginePreference: VectorEnginePreference = .auto,
        vectorSearchTimeout: Duration? = .seconds(10),
        topK: Int = 10,
        minScore: Float? = nil,
        timeRange: SearchTimeRange? = nil,
        frameFilter: FrameFilter? = nil,
        asOfMs: Int64 = Int64.max,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        structuredMemory: StructuredMemorySearchOptions = .init(),
        scopeContext: MemoryScopeContext? = nil,
        rrfK: Int = 60,
        previewMaxBytes: Int = 512,
        metadataLoadingThreshold: Int = 50,
        allowTimelineFallback: Bool = false,
        timelineFallbackLimit: Int = 10,
        enableRankingDiagnostics: Bool = false,
        rankingDiagnosticsTopK: Int = 10
    ) throws {
        self.init(
            query: query,
            uncheckedLane: try SearchLane.from(mode: lane.mode, embedding: lane.embedding),
            vectorEnginePreference: vectorEnginePreference,
            vectorSearchTimeout: vectorSearchTimeout,
            topK: topK,
            minScore: minScore,
            timeRange: timeRange,
            frameFilter: frameFilter,
            asOfMs: asOfMs,
            nowMs: nowMs,
            structuredMemory: structuredMemory,
            scopeContext: scopeContext,
            rrfK: rrfK,
            previewMaxBytes: previewMaxBytes,
            metadataLoadingThreshold: metadataLoadingThreshold,
            allowTimelineFallback: allowTimelineFallback,
            timelineFallbackLimit: timelineFallbackLimit,
            enableRankingDiagnostics: enableRankingDiagnostics,
            rankingDiagnosticsTopK: rankingDiagnosticsTopK
        )
    }

    /// Source-compatible constructor. Prefer the throwing `lane:` factory.
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
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
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
        self.init(
            query: query,
            uncheckedLane: SearchLane.compatible(mode: mode, embedding: embedding),
            vectorEnginePreference: vectorEnginePreference,
            vectorSearchTimeout: vectorSearchTimeout,
            topK: topK,
            minScore: minScore,
            timeRange: timeRange,
            frameFilter: frameFilter,
            asOfMs: asOfMs,
            nowMs: nowMs,
            structuredMemory: structuredMemory,
            scopeContext: scopeContext,
            rrfK: rrfK,
            previewMaxBytes: previewMaxBytes,
            metadataLoadingThreshold: metadataLoadingThreshold,
            allowTimelineFallback: allowTimelineFallback,
            timelineFallbackLimit: timelineFallbackLimit,
            enableRankingDiagnostics: enableRankingDiagnostics,
            rankingDiagnosticsTopK: rankingDiagnosticsTopK
        )
    }

    private init(
        query: String?,
        uncheckedLane: SearchLane,
        vectorEnginePreference: VectorEnginePreference,
        vectorSearchTimeout: Duration?,
        topK: Int,
        minScore: Float?,
        timeRange: SearchTimeRange?,
        frameFilter: FrameFilter?,
        asOfMs: Int64,
        nowMs: Int64,
        structuredMemory: StructuredMemorySearchOptions,
        scopeContext: MemoryScopeContext?,
        rrfK: Int,
        previewMaxBytes: Int,
        metadataLoadingThreshold: Int,
        allowTimelineFallback: Bool,
        timelineFallbackLimit: Int,
        enableRankingDiagnostics: Bool,
        rankingDiagnosticsTopK: Int
    ) {
        self.query = query
        self.lane = uncheckedLane
        self.vectorEnginePreference = vectorEnginePreference
        self.vectorSearchTimeout = vectorSearchTimeout
        self.topK = topK
        self.minScore = minScore
        self.timeRange = timeRange
        self.frameFilter = frameFilter
        self.asOfMs = asOfMs
        self.nowMs = nowMs
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
