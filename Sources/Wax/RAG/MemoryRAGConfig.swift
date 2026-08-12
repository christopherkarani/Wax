import Foundation

public extension Memory {
    /// Bounded FastRAG knobs exposed on ``Memory/Config-swift.struct``.
    ///
    /// Values are stored as given. Wax clamps them once while mapping into the
    /// package FastRAG builder; ``Memory/init(at:config:)`` does not throw
    /// ``WaxError/invalidConfiguration(reason:)`` for out-of-range RAG fields.
    struct RAGConfig: Sendable, Equatable {
        public var maxContextTokens: Int
        public var searchTopK: Int
        public var answerRerankWindow: Int
        public var answerDistractorPenalty: Float

        public init(
            maxContextTokens: Int = 1_500,
            searchTopK: Int = 24,
            answerRerankWindow: Int = 12,
            answerDistractorPenalty: Float = 0.30
        ) {
            self.maxContextTokens = maxContextTokens
            self.searchTopK = searchTopK
            self.answerRerankWindow = answerRerankWindow
            self.answerDistractorPenalty = answerDistractorPenalty
        }

        public static let `default` = RAGConfig(
            maxContextTokens: 1_500,
            searchTopK: 24,
            answerRerankWindow: 12,
            answerDistractorPenalty: 0.30
        )

        /// Clamp public knobs exactly once while mapping into package ``FastRAGConfig``.
        package func makeFastRAGConfig() -> FastRAGConfig {
            var rag = FastRAGConfig()
            rag.maxContextTokens = max(0, maxContextTokens)
            rag.searchTopK = max(0, searchTopK)
            rag.answerRerankWindow = max(0, answerRerankWindow)
            rag.answerDistractorPenalty = Self.clampDistractorPenalty(answerDistractorPenalty)
            return rag
        }

        package static func clampDistractorPenalty(_ value: Float) -> Float {
            if value == .infinity { return 1 }
            if value == -.infinity { return 0 }
            guard value.isFinite else { return 0.30 }
            return min(1, max(0, value))
        }
    }
}
