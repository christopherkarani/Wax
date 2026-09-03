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

    @Test
    func sameProjectAndRepoTagsMatchScopeIdentityNotBrokerCwd() {
        let nowMs: Int64 = 2_000_000_000_000
        let identity = MemoryScopeContext(
            cwdPath: "/tmp/other-cwd",
            repoName: "wax-recall-repo",
            projectName: "wax-recall"
        )
        let matching = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.project: "wax-recall",
                MemoryMetadataKeys.repo: "wax-recall-repo",
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs),
            ],
            scope: identity,
            nowMs: nowMs
        )
        #expect(matching.reasons.contains("same project"))
        #expect(matching.reasons.contains("same repo"))

        let foreignHit = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.project: "other-project",
                MemoryMetadataKeys.repo: "other-repo",
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs),
            ],
            scope: identity,
            nowMs: nowMs
        )
        #expect(foreignHit.reasons.contains("same project") == false)
        #expect(foreignHit.reasons.contains("same repo") == false)

        let brokerCwdScope = MemoryScopeContext(
            cwdPath: "/tmp/wax-recall",
            repoName: "other-cwd",
            projectName: "other-cwd"
        )
        let cwdMismatch = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.project: "wax-recall",
                MemoryMetadataKeys.repo: "wax-recall-repo",
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs),
            ],
            scope: brokerCwdScope,
            nowMs: nowMs
        )
        #expect(cwdMismatch.reasons.contains("same project") == false)
        #expect(cwdMismatch.reasons.contains("same repo") == false)
        #expect(cwdMismatch.reasons.contains("recently used") == false)
    }

    @Test
    func recentTagRequiresCreatedAtAgeOfAtMostThreeDays() {
        let nowMs: Int64 = 2_000_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000

        let twoDayNote = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - (2 * dayMs)),
            ],
            scope: nil,
            nowMs: nowMs
        )
        #expect(twoDayNote.reasons.contains("recent"))
        #expect(twoDayNote.reasons.contains("recently used") == false)

        let threeDayNote = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - (3 * dayMs)),
            ],
            scope: nil,
            nowMs: nowMs
        )
        #expect(threeDayNote.reasons.contains("recent"))

        let fourDayNote = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - (4 * dayMs)),
            ],
            scope: nil,
            nowMs: nowMs
        )
        #expect(fourDayNote.reasons.contains("recent") == false)
    }

    @Test
    func fortyDayDurableDecisionIsNotRecentAndIsNotAgePenalized() {
        let nowMs: Int64 = 2_000_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000

        func durableDecision(daysAgo: Int) -> (adjustment: Float, reasons: [String]) {
            MemorySemantics.rankingReasons(
                metadata: [
                    MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                    MemoryMetadataKeys.createdAtMs: String(nowMs - (Int64(daysAgo) * dayMs)),
                ],
                scope: nil,
                nowMs: nowMs
            )
        }

        let fortyDay = durableDecision(daysAgo: 40)
        let tenDay = durableDecision(daysAgo: 10)
        let hundredDay = durableDecision(daysAgo: 100)
        #expect(fortyDay.reasons.contains("recent") == false)
        #expect(hundredDay.reasons.contains("recent") == false)
        #expect(fortyDay.adjustment == tenDay.adjustment)
        #expect(hundredDay.adjustment == tenDay.adjustment)

        let tenDayWorkingNote = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - (10 * dayMs)),
            ],
            scope: nil,
            nowMs: nowMs
        )
        let hundredDayWorkingNote = MemorySemantics.rankingReasons(
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - (100 * dayMs)),
            ],
            scope: nil,
            nowMs: nowMs
        )
        #expect(hundredDayWorkingNote.adjustment < tenDayWorkingNote.adjustment)
        #expect(hundredDayWorkingNote.reasons.contains("recent") == false)
    }

    @Test
    func recentlyUsedIsASeparateAccessTagAndDurableNeverGetsStaleAccess() {
        let nowMs: Int64 = 2_000_000_000_000
        let hourMs: Int64 = 60 * 60 * 1000
        let dayMs: Int64 = 24 * 60 * 60 * 1000
        let durableMetadata = [
            MemoryMetadataKeys.type: MemoryType.decision.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
            MemoryMetadataKeys.createdAtMs: String(nowMs - (40 * dayMs)),
        ]
        let lockedMetadata = [
            MemoryMetadataKeys.type: MemoryType.fact.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
            MemoryMetadataKeys.createdAtMs: String(nowMs - (40 * dayMs)),
        ]
        let workingMetadata = [
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
            MemoryMetadataKeys.createdAtMs: String(nowMs - (40 * dayMs)),
        ]

        let ranking = MemorySemantics.rankingReasons(
            metadata: durableMetadata,
            scope: nil,
            nowMs: nowMs
        )
        #expect(ranking.reasons.contains("recent") == false)
        #expect(ranking.reasons.contains("recently used") == false)
        #expect(ranking.reasons.contains("stale access") == false)

        let recentAccess = FrameAccessStats(frameId: 1, nowMs: nowMs - (6 * hourMs))
        let recentUsed = MemorySemantics.accessReasons(
            stats: recentAccess,
            metadata: durableMetadata,
            nowMs: nowMs
        )
        #expect(recentUsed.reasons.contains("recently used"))
        #expect(recentUsed.reasons.contains("recent") == false)
        #expect(recentUsed.reasons.contains("stale access") == false)

        let dayOldAccess = FrameAccessStats(frameId: 2, nowMs: nowMs - (24 * hourMs))
        let stillRecent = MemorySemantics.accessReasons(
            stats: dayOldAccess,
            metadata: workingMetadata,
            nowMs: nowMs
        )
        #expect(stillRecent.reasons.contains("recently used"))

        let staleWindow = FrameAccessStats(frameId: 3, nowMs: nowMs - (25 * hourMs))
        let notRecentlyUsed = MemorySemantics.accessReasons(
            stats: staleWindow,
            metadata: workingMetadata,
            nowMs: nowMs
        )
        #expect(notRecentlyUsed.reasons.contains("recently used") == false)

        let staleStats = FrameAccessStats(frameId: 4, nowMs: nowMs - (90 * dayMs))
        let staleWorking = MemorySemantics.accessReasons(
            stats: staleStats,
            metadata: workingMetadata,
            nowMs: nowMs
        )
        #expect(staleWorking.adjustment < 0)
        #expect(staleWorking.reasons.contains("stale access"))
        #expect(staleWorking.reasons.contains("recently used") == false)

        let staleDurable = MemorySemantics.accessReasons(
            stats: staleStats,
            metadata: durableMetadata,
            nowMs: nowMs
        )
        #expect(staleDurable.adjustment == 0)
        #expect(staleDurable.reasons.contains("stale access") == false)

        let staleLocked = MemorySemantics.accessReasons(
            stats: staleStats,
            metadata: lockedMetadata,
            nowMs: nowMs
        )
        #expect(staleLocked.adjustment == 0)
        #expect(staleLocked.reasons.contains("stale access") == false)
    }
}
