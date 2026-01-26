import Foundation
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

    public var rrfK: Int
    public var previewMaxBytes: Int
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
        rrfK: Int = 60,
        previewMaxBytes: Int = 512,
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
        self.rrfK = rrfK
        self.previewMaxBytes = previewMaxBytes
        self.allowTimelineFallback = allowTimelineFallback
        self.timelineFallbackLimit = timelineFallbackLimit
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

    public init(
        includeDeleted: Bool = false,
        includeSuperseded: Bool = false,
        includeSurrogates: Bool = false,
        frameIds: Set<UInt64>? = nil
    ) {
        self.includeDeleted = includeDeleted
        self.includeSuperseded = includeSuperseded
        self.includeSurrogates = includeSurrogates
        self.frameIds = frameIds
    }
}
