import Testing
import Wax

@Test
func waxMemoryToolActionParsingIsCaseInsensitive() {
    #expect(WaxMemoryToolAction.parse("remember") == .remember)
    #expect(WaxMemoryToolAction.parse(" ReCaLl ") == .recall)
    #expect(WaxMemoryToolAction.parse("SEARCH") == .search)
    #expect(WaxMemoryToolAction.parse("invalid") == nil)
}

@Test
func waxMemoryToolConfigClampsTopKAndAlpha() {
    var config = WaxMemoryToolConfig.default
    config.searchTopK = 8
    config.maxSearchTopK = 20
    config.searchAlpha = 0.5

    #expect(config.topK(nil) == 8)
    #expect(config.topK(0) == 1)
    #expect(config.topK(100) == 20)

    #expect(config.alpha(nil) == 0.5)
    #expect(config.alpha(-1) == 0)
    #expect(config.alpha(2) == 1)
}

@Test
func waxMemoryToolRendererFormatsRecallAndTruncates() {
    let context = RAGContext(
        query: "preferences",
        items: [
            .init(
                kind: .expanded,
                frameId: 7,
                score: 0.95,
                sources: [.text, .vector],
                text: String(repeating: "x", count: 40)
            ),
            .init(
                kind: .snippet,
                frameId: 8,
                score: 0.8,
                sources: [.text],
                text: "second"
            ),
        ],
        totalTokens: 10
    )

    let output = WaxMemoryToolRenderer.renderRecall(
        query: "preferences",
        context: context,
        maxItems: 1,
        includeScores: true,
        maxItemCharacters: 10
    )

    #expect(output.contains("Memory context for \"preferences\""))
    #expect(output.contains("[expanded|text,vector score=0.9500]"))
    #expect(output.contains("…"))
    #expect(output.contains("more memory item(s) omitted"))
}

@Test
func waxMemoryToolRendererFormatsSearchFallback() {
    let output = WaxMemoryToolRenderer.renderSearch(
        query: "missing",
        hits: [],
        includeScores: false,
        maxItemCharacters: 120
    )
    #expect(output.contains("No memory search hits found"))
}
