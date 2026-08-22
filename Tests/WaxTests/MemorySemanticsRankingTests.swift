import Testing
@testable import Wax

@Suite("Memory semantics ranking")
struct MemorySemanticsRankingTests {
    @Test
    func recentHandoffOutranksGenericRecentLessonAtEqualRetrievalScore() {
        let nowMs: Int64 = 2_000_000_000_000
        let recent = String(nowMs - (60 * 60 * 1000))
        let handoff = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.handoff.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.ephemeral.rawValue,
                MemoryMetadataKeys.createdAtMs: recent,
            ],
            scope: nil,
            nowMs: nowMs
        )
        let lesson = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                MemoryMetadataKeys.createdAtMs: recent,
            ],
            scope: nil,
            nowMs: nowMs
        )

        #expect(handoff.adjustment > lesson.adjustment)
        #expect(handoff.reasons.contains("recent handoff"))
    }

    @Test
    func oldHandoffIsPenalizedAndMarkedStale() {
        let nowMs: Int64 = 2_000_000_000_000
        let old = String(nowMs - (30 * 24 * 60 * 60 * 1000))
        let handoff = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.handoff.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.ephemeral.rawValue,
                MemoryMetadataKeys.createdAtMs: old,
            ],
            scope: nil,
            nowMs: nowMs
        )

        #expect(handoff.adjustment < 0)
        #expect(handoff.reasons.contains("stale handoff"))
    }
}
