import Testing
@testable import Wax
import WaxCore

struct AccessRankingWindowTests {
    @Test(arguments: [
        // search path: multiplier 3, cap 16
        (requested: 10, enabled: true, multiplier: 3, cap: 16, expected: 30),
        (requested: 16, enabled: true, multiplier: 3, cap: 16, expected: 48),
        (requested: 17, enabled: true, multiplier: 3, cap: 16, expected: 17),
        (requested: 20, enabled: true, multiplier: 3, cap: 16, expected: 20),
        // FastRAG path: multiplier 2, cap 24
        (requested: 24, enabled: true, multiplier: 2, cap: 24, expected: 48),
        (requested: 25, enabled: true, multiplier: 2, cap: 24, expected: 25),
        (requested: 10, enabled: true, multiplier: 2, cap: 24, expected: 20),
        // disabled → requestedTopK
        (requested: 10, enabled: false, multiplier: 3, cap: 16, expected: 10),
        (requested: 24, enabled: false, multiplier: 2, cap: 24, expected: 24),
        (requested: 0, enabled: true, multiplier: 3, cap: 16, expected: 0),
    ])
    func candidateCountMatchesSearchAndFastRAGPolicies(
        requested: Int,
        enabled: Bool,
        multiplier: Int,
        cap: Int,
        expected: Int
    ) {
        let count = AccessRankingWindow.candidateCount(
            requestedTopK: requested,
            accessEnabled: enabled,
            multiplier: multiplier,
            applyWhenRequestedTopKAtMost: cap
        )
        #expect(count == expected)
    }

    @Test
    func applyAccessRankingDisabledIsIdentity() {
        let results = [
            result(frameId: 1, score: 0.40, preview: "alpha"),
            result(frameId: 2, score: 0.35, preview: "beta"),
        ]
        var stats = FrameAccessStats(frameId: 2, nowMs: 1_700_000_000_000)
        stats.accessCount = 32
        stats.engagementCount = 32
        stats.lastEngagementMs = stats.lastImpressionMs

        let ranked = RankedSearch.applyAccessRanking(
            results: results,
            query: "alpha",
            accessStats: [2: stats],
            nowMs: 1_700_000_000_000,
            maxWindow: 2,
            enabled: false
        )
        #expect(ranked == results)
    }

    @Test
    func applyAccessRankingEnabledMatchesAccessFrequencyRanker() {
        let nowMs: Int64 = 1_700_000_000_000
        let results = [
            result(frameId: 1, score: 0.50, preview: "shared token"),
            result(frameId: 2, score: 0.50, preview: "shared token"),
        ]
        var stale = FrameAccessStats(frameId: 1, nowMs: nowMs - 30 * 24 * 60 * 60 * 1000)
        stale.accessCount = 1
        stale.engagementCount = 1
        stale.lastEngagementMs = stale.lastImpressionMs
        var recent = FrameAccessStats(frameId: 2, nowMs: nowMs - 6 * 60 * 60 * 1000)
        recent.accessCount = 8
        recent.engagementCount = 8
        recent.lastEngagementMs = recent.lastImpressionMs
        let stats: [UInt64: FrameAccessStats] = [1: stale, 2: recent]

        let viaHelper = RankedSearch.applyAccessRanking(
            results: results,
            query: "shared token",
            accessStats: stats,
            nowMs: nowMs,
            maxWindow: 2,
            enabled: true
        )
        let viaRanker = AccessFrequencyRanker.rerank(
            results: results,
            query: "shared token",
            accessStats: stats,
            nowMs: nowMs,
            maxWindow: 2
        )
        #expect(viaHelper == viaRanker)
        #expect(viaHelper.map(\.frameId) == [2, 1])
    }

    private func result(frameId: UInt64, score: Float, preview: String) -> SearchResponse.Result {
        SearchResponse.Result(
            frameId: frameId,
            score: score,
            previewText: preview,
            sources: [.text]
        )
    }
}
