package struct TextSearchResult: Equatable, Sendable {
    package let frameId: UInt64
    package let score: Double
    package let snippet: String?

    package init(frameId: UInt64, score: Double, snippet: String?) {
        self.frameId = frameId
        self.score = score
        self.snippet = snippet
    }
}
