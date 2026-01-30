/// Unified search response.
public struct SearchResponse: Sendable, Equatable {
    public struct Result: Sendable, Equatable {
        public var frameId: UInt64
        public var score: Float
        public var previewText: String?
        public var sources: [Source]

        public init(frameId: UInt64, score: Float, previewText: String? = nil, sources: [Source]) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
        }
    }

    public enum Source: Sendable, Equatable {
        case text
        case vector
        case timeline
        case structuredMemory
    }

    public var results: [Result]

    public init(results: [Result]) {
        self.results = results
    }
}
