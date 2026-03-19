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

        public init(
            kind: ItemKind,
            frameId: UInt64,
            score: Float,
            sources: [Source],
            text: String,
            metadata: [String: String] = [:]
        ) {
            self.kind = kind
            self.frameId = frameId
            self.score = score
            self.sources = sources
            self.text = text
            self.metadata = metadata
        }
    }

    public var query: String
    public var items: [Item]
    public var totalTokens: Int

    public init(query: String, items: [Item], totalTokens: Int) {
        self.query = query
        self.items = items
        self.totalTokens = totalTokens
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

package extension RAGContext.Source {
    static func fromSearchSource(_ source: SearchResponse.Source) -> RAGContext.Source {
        switch source {
        case .text:
            return .text
        case .vector:
            return .vector
        case .timeline:
            return .timeline
        case .structuredMemory:
            return .structured
        }
    }

    static func fromSearchSources(_ sources: [SearchResponse.Source]) -> [RAGContext.Source] {
        if sources.isEmpty { return [.unknown] }
        return sources.map(fromSearchSource)
    }
}
