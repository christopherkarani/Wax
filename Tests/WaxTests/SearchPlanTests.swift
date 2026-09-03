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

    @Test
    func hybridIncludesBothLanesWithoutExactIntentWindow() {
        let plan = SearchPlan.make(
            SearchRequest(query: "hello world", mode: .hybrid(), nowMs: 0)
        )
        #expect(plan.includeText)
        #expect(plan.includeVector)
        #expect(plan.queryType == .exploratory)
        #expect(plan.exactIntentWindow == nil)
        #expect(plan.candidateLimit == 30)
        #expect(plan.matchPlan != nil)
    }

    @Test(arguments: [(1, 12), (10, 30), (20, 48)])
    func exactIntentWindowClampsToTwelveAndFortyEight(topK: Int, window: Int) {
        let plan = SearchPlan.make(SearchRequest(query: "7f3a91", topK: topK, nowMs: 0))
        #expect(plan.exactIntentWindow == window)
        #expect(plan.includeText)
        #expect(plan.includeVector == false)
    }

    @Test
    func callerFilterOverfetchesCandidateLimit() {
        let allowlist = SearchPlan.make(
            SearchRequest(
                query: "hello world",
                topK: 10,
                frameFilter: FrameFilter(frameIds: [1]),
                nowMs: 0
            )
        )
        #expect(allowlist.candidateLimit == 210)

        let metadata = SearchPlan.make(
            SearchRequest(
                query: "hello world",
                topK: 10,
                frameFilter: FrameFilter(
                    metadataFilter: MetadataFilter(requiredEntries: ["k": "v"])
                ),
                nowMs: 0
            )
        )
        #expect(metadata.candidateLimit == 210)

        let emptyMetadata = SearchPlan.make(
            SearchRequest(
                query: "hello world",
                topK: 10,
                frameFilter: FrameFilter(metadataFilter: MetadataFilter()),
                nowMs: 0
            )
        )
        #expect(emptyMetadata.candidateLimit == 30)
    }
}
