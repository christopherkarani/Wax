import Foundation

public struct RAGContext: Sendable, Equatable {
    public enum ItemKind: Sendable, Equatable { case snippet, expanded, surrogate }
    public enum Source: Sendable, Equatable {
        case text
        case vector
        case timeline
        case structured
        case unknown
    }

    public struct Item: Sendable, Equatable {
        public var kind: ItemKind
        public var frameId: UInt64
        public var score: Float
        public var sources: [Source]
        public var text: String
        public var metadata: [String: String]
        public var explanations: [String]

        public init(
            kind: ItemKind,
            frameId: UInt64,
            score: Float,
            sources: [Source],
            text: String,
            metadata: [String: String] = [:],
            explanations: [String] = []
        ) {
            self.kind = kind
            self.frameId = frameId
            self.score = score
            self.sources = sources
            self.text = text
            self.metadata = metadata
            self.explanations = explanations
        }
    }

    /// What happened to the query embedding for a search.
    public enum QueryEmbeddingState: String, Sendable, Equatable {
        /// The caller requested a text-only search; no embedding was attempted.
        case notRequested = "not_requested"
        /// The query embedding was computed and the vector lane ran.
        case available = "available"
        /// Query embedding timed out; the search fell back to the text lane.
        case timeout = "timeout"
        /// Query embedding is paused by the timeout circuit breaker; text lane used.
        case circuitOpen = "circuit_open"
        /// No embedding provider is configured; text lane used.
        case noEmbedder = "no_embedder"
        /// Vector search is disabled for this store; text lane used.
        case vectorDisabled = "vector_disabled"
        /// Query embedding failed; the search fell back to the text lane.
        case failed = "failed"
    }

    /// Retrieval diagnostics for a search: what was asked for vs. what actually ran.
    ///
    /// Wax degrades to the text lane when the vector lane is unavailable. Compare
    /// ``requestedMode`` and ``effectiveMode`` (and check ``queryEmbeddingState``)
    /// to detect that degradation instead of assuming it from scores.
    ///
    /// For logs, MCP, or docs that need the historical string form (`"text"`,
    /// `"vector"`, `"hybrid(alpha=0.500)"`), use ``SearchMode/diagnosticsSummary``.
    public struct Diagnostics: Sendable, Equatable {
        /// The retrieval mode requested by the caller.
        public var requestedMode: SearchMode
        /// The retrieval mode actually executed (e.g. ``SearchMode/textOnly`` when the vector lane was unavailable).
        public var effectiveMode: SearchMode
        /// What happened to the query embedding for this search.
        public var queryEmbeddingState: QueryEmbeddingState

        public init(
            requestedMode: SearchMode,
            effectiveMode: SearchMode,
            queryEmbeddingState: QueryEmbeddingState
        ) {
            self.requestedMode = requestedMode
            self.effectiveMode = effectiveMode
            self.queryEmbeddingState = queryEmbeddingState
        }
    }

    public var query: String
    public var items: [Item]
    public var totalTokens: Int
    /// Retrieval diagnostics for this search. `nil` for contexts built by lower-level
    /// APIs that do not run the retrieval pipeline.
    public var diagnostics: Diagnostics?

    public init(
        query: String,
        items: [Item],
        totalTokens: Int,
        diagnostics: Diagnostics? = nil
    ) {
        self.query = query
        self.items = items
        self.totalTokens = totalTokens
        self.diagnostics = diagnostics
    }
}

public extension RAGContext.Source {
    var rawValue: String {
        switch self {
        case .text:
            return "text"
        case .vector:
            return "vector"
        case .timeline:
            return "timeline"
        case .structured:
            return "structured"
        case .unknown:
            return "unknown"
        }
    }
}
