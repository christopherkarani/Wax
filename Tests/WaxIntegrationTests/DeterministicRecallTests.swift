import Foundation
import Testing
@testable import Wax
import WaxCore

@Suite
struct DeterministicRecallTests {
    private static let fixedNowMs: Int64 = 1_700_000_000_000
    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    @Test
    func sameStoreQueryAndFixedNowYieldIdenticalRecallAndSearchResults() async throws {
        try await TempFiles.withTempFile { url in
            do {
                let ingest = try await MemoryOrchestrator(
                    at: url,
                    config: TestHelpers.defaultMemoryConfig(),
                    embedder: DeterministicTextEmbedder()
                )
                try await ingest.remember("Waxfile alpha stores deployment decisions for the pipeline.")
                try await ingest.remember("Waxfile beta records lessons learned from past outages.")
                try await ingest.remember("Waxfile gamma holds user preferences for editor tooling.")
                try await ingest.flush()
                try await ingest.close()
            }

            var config = TestHelpers.defaultMemoryConfig()
            config.rag.deterministicNowMs = Self.fixedNowMs
            let orchestrator = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: DeterministicTextEmbedder()
            )

            let recall1 = try await orchestrator.recall(query: "waxfile")
            let recall2 = try await orchestrator.recall(query: "waxfile")
            #expect(!recall1.items.isEmpty)
            #expect(recall1 == recall2)

            let hits1 = try await orchestrator.search(
                query: "waxfile",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil
            )
            let hits2 = try await orchestrator.search(
                query: "waxfile",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil
            )
            #expect(!hits1.isEmpty)
            #expect(hits1.map(\.frameId) == hits2.map(\.frameId))
            #expect(hits1.map(\.score) == hits2.map(\.score))
            #expect(hits1.map(\.explanations) == hits2.map(\.explanations))

            try await orchestrator.close()
        }
    }

    @Test
    func documentAgeRecencyBoostFlipsRankingAcrossNinetyDayBoundary() {
        let nowA = Self.fixedNowMs
        let day = Self.dayMs

        func metadata(createdAtMs: Int64) -> [String: String] {
            [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.createdAtMs: String(createdAtMs),
            ]
        }

        // Notes default to `.working` durability, so both stay subject to the
        // documented >90 day penalty (-0.35) and the <=3 day "recent" boost (+0.15).
        let older = metadata(createdAtMs: nowA - 100 * day)
        let fresher = metadata(createdAtMs: nowA - day)

        let scoredAtA = (
            older: MemorySemantics.rankingReasons(metadata: older, scope: nil, nowMs: nowA),
            fresher: MemorySemantics.rankingReasons(metadata: fresher, scope: nil, nowMs: nowA)
        )
        #expect(scoredAtA.fresher.reasons.contains("recent"))
        #expect(scoredAtA.older.reasons.isEmpty)
        #expect(abs(scoredAtA.fresher.adjustment - 0.20) < 0.001)
        #expect(abs(scoredAtA.older.adjustment - (-0.30)) < 0.001)

        // With base text scores 0.60 vs 0.50, the recency boost puts the younger
        // document on top even though its raw score is lower.
        let compositeAtA = (
            older: Float(0.60) + scoredAtA.older.adjustment,
            fresher: Float(0.50) + scoredAtA.fresher.adjustment
        )
        #expect(compositeAtA.fresher > compositeAtA.older)

        // Past the 90-day boundary both documents take the silent -0.35 penalty,
        // the "recent" reason disappears, and the higher base score wins again.
        let nowB = nowA + 92 * day
        let scoredAtB = (
            older: MemorySemantics.rankingReasons(metadata: older, scope: nil, nowMs: nowB),
            fresher: MemorySemantics.rankingReasons(metadata: fresher, scope: nil, nowMs: nowB)
        )
        #expect(scoredAtB.fresher.reasons.isEmpty)
        #expect(scoredAtB.older.reasons.isEmpty)
        #expect(abs(scoredAtB.fresher.adjustment - (-0.30)) < 0.001)
        #expect(abs(scoredAtB.older.adjustment - (-0.30)) < 0.001)

        let compositeAtB = (
            older: Float(0.60) + scoredAtB.older.adjustment,
            fresher: Float(0.50) + scoredAtB.fresher.adjustment
        )
        #expect(compositeAtB.older > compositeAtB.fresher)
    }

    @Test
    func injectedNowDrivesAccessRecencyExplanationWithinOneRequest() async throws {
        try await TempFiles.withTempFile { url in
            let remembered: MemoryOrchestrator.RememberResult
            do {
                let ingest = try await MemoryOrchestrator(
                    at: url,
                    config: TestHelpers.defaultMemoryConfig(),
                    embedder: DeterministicTextEmbedder()
                )
                remembered = try await ingest.remember("Waxfile delta tracks rollout status across regions.")
                try await ingest.flush()
                try await ingest.close()
            }

            let clock = MutableClock(Self.fixedNowMs)
            var config = TestHelpers.defaultMemoryConfig()
            config.enableAccessStatsScoring = true
            let orchestrator = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: DeterministicTextEmbedder(),
                nowMsProvider: { clock.nowMs }
            )

            func runSearch() async throws -> [MemoryOrchestrator.MemorySearchHit] {
                try await orchestrator.search(
                    query: "waxfile",
                    mode: .hybrid(alpha: 0.5),
                    topK: 5,
                    frameFilter: nil
                )
            }

            // Explicit use stamps access stats with the injected clock. Search
            // itself does not record, so consecutive searches stay deterministic.
            await orchestrator.recordAccess(frameId: remembered.frameId)

            // Same injected now: the previous access is <24h old, so the documented
            // "recently used" reason appears.
            let warmHits = try await runSearch()
            #expect(!warmHits.isEmpty)
            #expect(warmHits.contains { $0.explanations.contains("recently used") })

            // Advancing the injected clock past the 24h window removes the reason;
            // nothing else about the store or query changed.
            clock.advance(ms: 2 * Self.dayMs)
            let coldHits = try await runSearch()
            #expect(!coldHits.isEmpty)
            #expect(coldHits.allSatisfy { !$0.explanations.contains("recently used") })

            try await orchestrator.close()
        }
    }
}
