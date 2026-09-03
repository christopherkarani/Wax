import Testing
@testable import Wax

struct SearchPlanTests {
    @Test
    func emptyQueryIsExploratoryTextOnly() {
        let whitespace = SearchPlan.make(SearchRequest(query: "   ", nowMs: 0))
        #expect(whitespace.trimmedQuery == "")
        #expect(whitespace.queryType == .exploratory)
        #expect(whitespace.includeText)
        #expect(whitespace.includeVector == false)
        #expect(whitespace.exactIntentWindow == nil)
        #expect(whitespace.matchPlan == nil)
        #expect(whitespace.weights == FusionWeights(bm25: 0.4, vector: 0.5, temporal: 0.1))

        let omitted = SearchPlan.make(SearchRequest(query: nil, nowMs: 0))
        #expect(omitted.trimmedQuery == nil)
        #expect(omitted.queryType == .exploratory)
        #expect(omitted.includeText)
        #expect(omitted.includeVector == false)
        #expect(omitted.matchPlan == nil)
    }

    @Test
    func factualIdentifierPlansLexicalLaneAndExactIntentWindow() {
        let plan = SearchPlan.make(SearchRequest(query: "7f3a91", topK: 10, nowMs: 0))
        #expect(plan.trimmedQuery == "7f3a91")
        #expect(plan.queryType == .factual)
        #expect(plan.includeText)
        #expect(plan.includeVector == false)
        #expect(plan.exactIntentWindow == 30)
        #expect(plan.candidateLimit == 30)
        #expect(plan.matchPlan != nil)
        #expect(plan.weights == FusionWeights(bm25: 0.7, vector: 0.3, temporal: 0.0))
    }

    @Test
    func vectorOnlyWithoutEmbeddingSetsIncludeFlagsAndDoesNotThrow() {
        let missing = SearchPlan.make(
            SearchRequest(query: "7f3a91", embedding: nil, mode: .vectorOnly, nowMs: 0)
        )
        #expect(missing.includeText == false)
        #expect(missing.includeVector)
        #expect(missing.exactIntentWindow == nil)
        #expect(missing.queryType == .factual)

        let empty = SearchPlan.make(
            SearchRequest(query: "7f3a91", embedding: [], mode: .vectorOnly, nowMs: 0)
        )
        #expect(empty.includeText == false)
        #expect(empty.includeVector)
        #expect(empty.exactIntentWindow == nil)
    }
}
