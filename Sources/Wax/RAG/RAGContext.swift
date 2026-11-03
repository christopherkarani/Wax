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
        /// Stored vectors come from a superseded embedding model and are being re-embedded;
        /// the text lane was used.
        case vectorsRebuilding = "vectors_rebuilding"
    }

    /// Retrieval diagnostics for a search: what was asked for vs. what actually ran.
    ///
    /// Wax degrades to the text lane when the vector lane is unavailable. Compare
    /// ``requestedMode`` and ``effectiveMode`` (and check ``queryEmbeddingState``)
    /// to detect that degradation instead of assuming it from scores.
    ///
    /// Hybrid or vector **effective** retrieval always implies ``QueryEmbeddingState/available``.
    /// The public memberwise triple init is unavailable; `Memory.search` produces
    /// this value. For logs, MCP, or docs that need the historical string form
    /// (`"text"`, `"vector"`, `"hybrid(alpha=0.500)"`), use ``SearchMode/diagnosticsSummary``.
    public struct Diagnostics: Sendable, Equatable {
        private enum Kind: Sendable, Equatable {
            /// Text lane ran. Requested may be text or a degraded hybrid/vector search.
            case text(requested: SearchMode, embedding: QueryEmbeddingState)
            /// Vector lane ran. Embedding is always ``QueryEmbeddingState/available``.
            case vector(requested: SearchMode, effective: SearchMode)
        }

        private let kind: Kind

        /// The retrieval mode requested by the caller.
        public var requestedMode: SearchMode {
            switch kind {
            case .text(let requested, _), .vector(let requested, _):
                return requested
            }
        }

        /// The retrieval mode actually executed (e.g. ``SearchMode/textOnly`` when the vector lane was unavailable).
        public var effectiveMode: SearchMode {
            switch kind {
            case .text:
                return .textOnly
            case .vector(_, let effective):
                return effective
            }
        }

        /// What happened to the query embedding for this search.
        public var queryEmbeddingState: QueryEmbeddingState {
            switch kind {
            case .text(_, let embedding):
                return embedding
            case .vector:
                return .available
            }
        }

        /// Text lane ran. ``effectiveMode`` is always ``SearchMode/textOnly``.
        package static func text(
            requested requestedMode: SearchMode,
            embedding queryEmbeddingState: QueryEmbeddingState
        ) -> Diagnostics {
            Diagnostics(kind: .text(requested: requestedMode, embedding: queryEmbeddingState))
        }

        /// Vector lane ran. ``queryEmbeddingState`` is always ``QueryEmbeddingState/available``.
        /// Passing ``SearchMode/textOnly`` as `effective` degrades to ``text(requested:embedding:)``.
        package static func vector(
            requested requestedMode: SearchMode,
            effective effectiveMode: SearchMode
        ) -> Diagnostics {
            switch effectiveMode {
            case .textOnly:
                return text(requested: requestedMode, embedding: .available)
            case .vectorOnly, .hybrid:
                return Diagnostics(kind: .vector(requested: requestedMode, effective: effectiveMode))
            }
        }

        @available(*, unavailable, message: "Diagnostics is produced by Memory.search; hybrid/vector effective requires an embedding")
        public init(
            requestedMode: SearchMode,
            effectiveMode: SearchMode,
            queryEmbeddingState: QueryEmbeddingState
        ) {
            fatalError("RAGContext.Diagnostics memberwise init is unavailable")
        }

        private init(kind: Kind) {
            self.kind = kind
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
