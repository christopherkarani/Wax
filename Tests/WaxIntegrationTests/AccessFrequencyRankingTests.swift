import Foundation
import Testing
@testable import Wax

@Test
func accessFrequencyScoringIsEnabledByDefaultAtPublicConfig() {
    #expect(Memory.Config.default.enableAccessStatsScoring)
    #expect(OrchestratorConfig.default.enableAccessStatsScoring)
}

@Test
func accessFrequencyDisabledModeLeavesCandidatesUntouched() {
    let results = [
        makeAccessRankingResult(frameId: 1, score: 0.40, preview: "alpha"),
        makeAccessRankingResult(frameId: 2, score: 0.35, preview: "beta"),
    ]
    var stats = FrameAccessStats(frameId: 2, nowMs: 1_700_000_000_000)
    stats.accessCount = 32

    let ranked = AccessFrequencyRanker.rerank(
        results: results,
        query: "alpha",
        accessStats: [2: stats],
        nowMs: 1_700_000_000_000,
        maxWindow: 2
    )

    // The caller's disabled path never invokes the ranker; an empty stats map
    // is also a no-op so it is safe for shared search plumbing.
    let disabled = AccessFrequencyRanker.rerank(
        results: results,
        query: "alpha",
        accessStats: [:],
        nowMs: 1_700_000_000_000,
        maxWindow: 2
    )
    #expect(disabled == results)
    #expect(ranked.first?.frameId == 2)
    #expect((ranked.first?.score ?? 0) > results[1].score)
}

@Test
func accessFrequencyDemotesStaleLowUseAndExplainsPublishedAdjustment() {
    let nowMs: Int64 = 1_700_000_000_000
    let results = [
        makeAccessRankingResult(frameId: 1, score: 0.50, preview: "shared token"),
        makeAccessRankingResult(frameId: 2, score: 0.50, preview: "shared token"),
    ]
    var stale = FrameAccessStats(frameId: 1, nowMs: nowMs - 30 * dayMs)
    stale.accessCount = 1
    var recent = FrameAccessStats(frameId: 2, nowMs: nowMs - 6 * hourMs)
    recent.accessCount = 8

    let ranked = AccessFrequencyRanker.rerank(
        results: results,
        query: "shared token",
        accessStats: [1: stale, 2: recent],
        nowMs: nowMs,
        maxWindow: 2
    )

    #expect(ranked.map(\.frameId) == [2, 1])
    #expect(ranked[0].score > results[1].score)
    #expect(ranked[1].score < results[0].score)
    #expect(ranked[0].explanations.contains("repeated use"))
    #expect(ranked[1].explanations.contains("stale access"))

    let recentAdjustment = AccessFrequencyRanker.adjustment(
        stats: recent,
        metadata: ranked[0].metadata,
        nowMs: nowMs
    )
    #expect(abs((ranked[0].score - results[1].score) - recentAdjustment) < 0.0001)
}

@Test
func accessFrequencyProtectsExactIdentifierAndDurablePolicy() {
    let nowMs: Int64 = 1_700_000_000_000
    let exact = makeAccessRankingResult(
        frameId: 1,
        // The lexical lane gives explicit identifier hits a strong base score;
        // access scoring must not erase that protection.
        score: 0.99,
        preview: "deployment token Atlas-42 is locked",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
        ]
    )
    let neighbor = makeAccessRankingResult(
        frameId: 2,
        score: 0.79,
        preview: "deployment token Atlas context"
    )
    let staleExact = FrameAccessStats(frameId: 1, nowMs: nowMs - 90 * dayMs)
    var recentNeighbor = FrameAccessStats(frameId: 2, nowMs: nowMs)
    recentNeighbor.accessCount = 32

    let ranked = AccessFrequencyRanker.rerank(
        results: [exact, neighbor],
        query: "Atlas-42",
        accessStats: [1: staleExact, 2: recentNeighbor],
        nowMs: nowMs,
        maxWindow: 2
    )
    #expect(ranked.first?.frameId == exact.frameId)

    let durable = makeAccessRankingResult(
        frameId: 3,
        score: 0.50,
        preview: "durable fact",
        metadata: [MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue]
    )
    let durableStats = FrameAccessStats(frameId: 3, nowMs: nowMs - 90 * dayMs)
    #expect(
        AccessFrequencyRanker.adjustment(
            stats: durableStats,
            metadata: durable.metadata,
            nowMs: nowMs
        ) == 0
    )
}

@Test
func accessFrequencyAdjustmentIsBoundedAgainstRichGetRicherAmplification() {
    let nowMs: Int64 = 1_700_000_000_000
    var saturated = FrameAccessStats(frameId: 1, nowMs: nowMs)
    saturated.accessCount = UInt32.max
    let positive = AccessFrequencyRanker.adjustment(stats: saturated, nowMs: nowMs)
    #expect(positive == AccessFrequencyRanker.maximumAdjustment)

    let stale = FrameAccessStats(frameId: 2, nowMs: nowMs - 365 * dayMs)
    let negative = AccessFrequencyRanker.adjustment(stats: stale, nowMs: nowMs)
    #expect(negative >= AccessFrequencyRanker.minimumAdjustment)
}

@Test
func accessFrequencyKeepsPublishedScoreInUnitInterval() {
    let nowMs: Int64 = 1_700_000_000_000
    var stats = FrameAccessStats(frameId: 1, nowMs: nowMs)
    stats.accessCount = UInt32.max
    let result = makeAccessRankingResult(frameId: 1, score: 0.99, preview: "boundary")

    let ranked = AccessFrequencyRanker.rerank(
        results: [result],
        query: "boundary",
        accessStats: [1: stats],
        nowMs: nowMs,
        maxWindow: 1
    )

    #expect(ranked[0].score >= 0)
    #expect(ranked[0].score <= 1)
}

@Test
func accessFrequencyCounterSaturatesAtUInt32Maximum() async {
    let manager = AccessStatsManager()
    await manager.importStats([
        FrameAccessStats(frameId: 1, nowMs: 1_700_000_000_000)
    ].map { stat in
        var saturated = stat
        saturated.accessCount = UInt32.max
        return saturated
    })
    await manager.recordAccess(frameId: 1, nowMs: 1_700_000_000_001)
    #expect(await manager.getStats(frameId: 1)?.accessCount == UInt32.max)
}

@Test
func accessFrequencyStatsPersistAndReloadAtOrchestratorSeam() async throws {
    try await TempFiles.withTempFile { url in
        let nowMs: Int64 = 1_700_000_000_000
        var config = TestHelpers.defaultMemoryConfig(vector: false)
        config.enableAccessStatsScoring = true
        config.rag.deterministicNowMs = nowMs

        let memory = try await MemoryOrchestrator(at: url, config: config)
        let remembered = try await memory.remember("access-frequency-persistence-token")
        _ = try await memory.search(
            query: "access-frequency-persistence-token",
            mode: .textOnly,
            topK: 1
        )
        try await memory.flush()
        try await memory.close()

        let reopened = try await MemoryOrchestrator(at: url, config: config)
        let stats = await reopened.accessStatsSnapshot()
        #expect(stats[remembered.frameId]?.accessCount == 1)
        try await reopened.close()
    }
}

private let hourMs: Int64 = 60 * 60 * 1000
private let dayMs: Int64 = 24 * hourMs

private func makeAccessRankingResult(
    frameId: UInt64,
    score: Float,
    preview: String,
    metadata: [String: String] = [:]
) -> SearchResponse.Result {
    SearchResponse.Result(
        frameId: frameId,
        score: score,
        previewText: preview,
        sources: [.text],
        metadata: metadata
    )
}
