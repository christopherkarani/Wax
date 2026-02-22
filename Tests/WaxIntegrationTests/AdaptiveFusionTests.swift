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

@Test func customAdaptiveFusionFallsBackWhenQueryTypeMissing() {
    let config = AdaptiveFusionConfig(
        weights: [
            .factual: FusionWeights(bm25: 0.9, vector: 0.1, temporal: 0),
        ]
    )

    let missingTypeWeights = config.weights(for: .semantic)
    #expect(missingTypeWeights == FusionWeights(bm25: 0.5, vector: 0.5))
}
