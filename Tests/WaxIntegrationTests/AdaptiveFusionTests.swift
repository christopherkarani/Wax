import Testing
import Wax

// Equal lane weights beat the old per-type split on LongMemEval and LoCoMo
// retrieval: the classifier's guess is wrong often enough to cost recall.
@Test(arguments: QueryType.allCases)
func textAndVectorLanesWeighEqually(queryType: QueryType) {
    let weights = AdaptiveFusionConfig.default.weights(for: queryType)
    #expect(weights.bm25 == weights.vector)
}

@Test func temporalQueryAddsRecencyBelowRelevance() {
    let weights = AdaptiveFusionConfig.default.weights(for: .temporal)
    #expect(weights.temporal > 0)
    #expect(weights.temporal < weights.bm25)
}

@Test func exploratoryQueryIsBalanced() {
    let weights = AdaptiveFusionConfig.default.weights(for: .exploratory)
    #expect(abs(weights.bm25 - weights.vector) <= 0.1)
}

@Test func identifierQueryIsNotExploratory() {
    let queryType = RuleBasedQueryClassifier.classify("7f3a91")
    #expect(queryType != .exploratory)
}

