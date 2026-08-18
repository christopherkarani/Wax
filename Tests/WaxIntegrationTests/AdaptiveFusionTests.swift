import Testing
import Wax

@Test func factualQueryFavorsBM25() {
    let weights = AdaptiveFusionConfig.default.weights(for: .factual)
    #expect(weights.bm25 > weights.vector)
}

@Test func semanticQueryFavorsVector() {
    let weights = AdaptiveFusionConfig.default.weights(for: .semantic)
    #expect(weights.vector > weights.bm25)
}

@Test func temporalQueryIncludesTimeWeight() {
    let weights = AdaptiveFusionConfig.default.weights(for: .temporal)
    #expect(weights.temporal > 0.3)
}

@Test func exploratoryQueryIsBalanced() {
    let weights = AdaptiveFusionConfig.default.weights(for: .exploratory)
    #expect(abs(weights.bm25 - weights.vector) <= 0.1)
}

@Test func identifierQueryUsesLexicalFirstWeights() {
    let queryType = RuleBasedQueryClassifier.classify("7f3a91")
    let weights = AdaptiveFusionConfig.default.weights(for: queryType)
    #expect(queryType != .exploratory)
    #expect(weights.bm25 > weights.vector)
}

@Test func factualHybridLaneWeightsKeepExclusiveTextAheadOfExclusiveVector() {
    let weights = AdaptiveFusionConfig.default.weights(for: .factual)
    let alpha: Float = 0.5
    let textWeight = weights.bm25 * alpha
    let vectorWeight = weights.vector * (1 - alpha)
    #expect(textWeight > vectorWeight)
}

