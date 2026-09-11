import Testing
@testable import Wax

@Suite("Unified ranking")
struct UnifiedRankingTests {
    private static let nowMs: Int64 = 1_700_000_000_000
    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    @Test
    func semanticMemoryRerankPrefersRecentNoteAtEqualFusedScore() {
        let older = noteResult(
            frameId: 1,
            createdAtMs: Self.nowMs - 100 * Self.dayMs
        )
        let fresher = noteResult(
            frameId: 2,
            createdAtMs: Self.nowMs - Self.dayMs
        )

        let ranked = UnifiedRanking.semanticMemoryRerank(
            results: [older, fresher],
            scopeContext: nil,
            nowMs: Self.nowMs,
            maxWindow: 10
        )

        #expect(ranked.map(\.frameId) == [2, 1])

        let expectedFresher = MemorySemantics.rankingReasons(
            metadata: fresher.metadata,
            scope: nil,
            nowMs: Self.nowMs
        )
        let expectedOlder = MemorySemantics.rankingReasons(
            metadata: older.metadata,
            scope: nil,
            nowMs: Self.nowMs
        )
        #expect(expectedFresher.reasons.contains("recent"))
        #expect(!expectedOlder.reasons.contains("recent"))
        #expect(ranked[0].explanations.contains("recent"))
        #expect(!ranked[1].explanations.contains("recent"))
        #expect(abs(ranked[0].score - (1.0 + expectedFresher.adjustment)) < 0.0001)
        #expect(abs(ranked[1].score - (1.0 + expectedOlder.adjustment)) < 0.0001)
        #expect(expectedFresher.adjustment > expectedOlder.adjustment)
    }

    @Test
    func semanticMemoryRerankUsesNowMsNotAsOfMs() {
        let older = noteResult(
            frameId: 1,
            createdAtMs: Self.nowMs - 100 * Self.dayMs
        )
        let fresher = noteResult(
            frameId: 2,
            createdAtMs: Self.nowMs - Self.dayMs
        )

        // asOfMs is a structured-fact cutoff (often Int64.max). Ranking-now
        // must stay the injected nowMs even when asOfMs would look like "live".
        let rankedAtFixedNow = UnifiedRanking.semanticMemoryRerank(
            results: [older, fresher],
            scopeContext: nil,
            nowMs: Self.nowMs,
            maxWindow: 10
        )
        let rankedPastNinetyDays = UnifiedRanking.semanticMemoryRerank(
            results: [older, fresher],
            scopeContext: nil,
            nowMs: Self.nowMs + 92 * Self.dayMs,
            maxWindow: 10
        )

        #expect(rankedAtFixedNow.map(\.frameId) == [2, 1])
        #expect(rankedAtFixedNow[0].explanations.contains("recent"))
        #expect(!rankedPastNinetyDays[0].explanations.contains("recent"))
        #expect(!rankedPastNinetyDays[1].explanations.contains("recent"))
        #expect(rankedPastNinetyDays.map(\.frameId) == [1, 2])
    }

    @Test
    func distinctiveTokenRerankPromotesRecentLexicalFactOverOldVectorLesson() {
        let query = "why agents use text search instead of vector waxmcp recall"
        let oldLesson = SearchResponse.Result(
            frameId: 1,
            score: 1.0,
            previewText: "MiniLM reciprocal rank fusion blends embedding neighbors for session memory.",
            sources: [.vector],
            metadata: [
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                MemoryMetadataKeys.createdAtMs: String(Self.nowMs - 14 * Self.dayMs),
            ]
        )
        let recentFact = SearchResponse.Result(
            frameId: 2,
            score: 0.3,
            previewText: "Agents use text search because the waxmcp playbook hard-codes recall mode text.",
            sources: [.text],
            metadata: [
                MemoryMetadataKeys.type: MemoryType.fact.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                MemoryMetadataKeys.createdAtMs: String(Self.nowMs - Self.dayMs),
            ]
        )

        let ranked = UnifiedRanking.distinctiveTokenRerank(
            results: [oldLesson, recentFact],
            query: query,
            nowMs: Self.nowMs,
            maxWindow: 10
        )

        #expect(ranked.map(\.frameId) == [2, 1])
        #expect(ranked[0].explanations.contains("distinctive token overlap"))
        #expect(ranked[0].explanations.contains("recent lexical match"))
        #expect(ranked[0].score > ranked[1].score)
    }

    @Test
    func distinctiveTokenRerankDoesNotPromoteRecentNoiseWithoutOverlap() {
        let query = "why agents use text search instead of vector waxmcp recall"
        let lexical = SearchResponse.Result(
            frameId: 1,
            score: 0.4,
            previewText: "Agents use text search in waxmcp recall.",
            sources: [.text],
            metadata: [
                MemoryMetadataKeys.type: MemoryType.fact.rawValue,
                MemoryMetadataKeys.createdAtMs: String(Self.nowMs - 20 * Self.dayMs),
            ]
        )
        let recentNoise = SearchResponse.Result(
            frameId: 2,
            score: 0.9,
            previewText: "Grocery list: milk eggs bread.",
            sources: [.vector],
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.createdAtMs: String(Self.nowMs - Self.dayMs),
            ]
        )

        let ranked = UnifiedRanking.distinctiveTokenRerank(
            results: [recentNoise, lexical],
            query: query,
            nowMs: Self.nowMs,
            maxWindow: 10
        )

        #expect(ranked.map(\.frameId) == [1, 2])
        #expect(ranked[0].explanations.contains("distinctive token overlap"))
        #expect(ranked[0].explanations.contains("recent lexical match") == false)
    }

    @Test
    func identifierExactMatchRerankPromotesTokenBoundaryHit() {
        let neighbor = SearchResponse.Result(
            frameId: 1,
            score: 1.2,
            previewText: "nearby prose about agent brokers",
            sources: [.text]
        )
        let exact = SearchResponse.Result(
            frameId: 2,
            score: 0.4,
            previewText: "id=build.agent_v2 in the rollout note",
            sources: [.text]
        )

        let ranked = UnifiedRanking.identifierExactMatchRerank(
            results: [neighbor, exact],
            query: "build.agent_v2",
            maxWindow: 10
        )

        #expect(ranked.map(\.frameId) == [2, 1])
        #expect(ranked[0].explanations.contains("exact identifier match"))
        #expect(ranked[0].score > ranked[1].score)
    }

    @Test
    func identifierExactMatchRerankUsesSharedDehighlightHelper() {
        let neighbor = SearchResponse.Result(
            frameId: 1,
            score: 1.2,
            previewText: "nearby prose about agent brokers",
            sources: [.text]
        )
        // Highlight markers sit inside identifier glue; ranking must strip
        // them or the contiguous identifier needle never matches.
        let exact = SearchResponse.Result(
            frameId: 2,
            score: 0.4,
            previewText: "id=build.[agent]_v2 in the rollout note",
            sources: [.text]
        )

        let ranked = UnifiedRanking.identifierExactMatchRerank(
            results: [neighbor, exact],
            query: "build.agent_v2",
            maxWindow: 10
        )

        #expect(UnifiedRanking.dehighlightedPreviewText(exact.previewText ?? "").contains("build.agent_v2"))
        #expect(ranked.map(\.frameId) == [2, 1])
        #expect(ranked[0].explanations.contains("exact identifier match"))
    }

    private func noteResult(frameId: UInt64, createdAtMs: Int64) -> SearchResponse.Result {
        SearchResponse.Result(
            frameId: frameId,
            score: 1.0,
            sources: [.text],
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.createdAtMs: String(createdAtMs),
            ]
        )
    }
}
