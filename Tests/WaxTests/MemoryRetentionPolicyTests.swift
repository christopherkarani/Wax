import Foundation
import Testing
@testable import Wax

@Test
func keepScorePinsLockedAndReviewedFrames() {
    let nowMs: Int64 = 1_700_000_000_000
    let locked = MemoryRetention.keepScore(
        type: .note,
        durability: .locked,
        reviewed: false,
        engagementCount: 0,
        lastEngagementMs: 0,
        nowMs: nowMs
    )
    let working = MemoryRetention.keepScore(
        type: .note,
        durability: .working,
        reviewed: false,
        engagementCount: 0,
        lastEngagementMs: 0,
        nowMs: nowMs
    )
    #expect(locked > working)
    #expect(locked >= 0.25)
}

@Test
func lockedFramesAreNeverColdOrQuarantined() {
    let nowMs: Int64 = 1_700_000_000_000
    let created = nowMs - 400 * 24 * 60 * 60 * 1000
    let metadata = [
        MemoryMetadataKeys.type: MemoryType.decision.rawValue,
        MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
        MemoryMetadataKeys.createdAtMs: String(created),
    ]
    #expect(
        MemoryRetention.isCold(metadata: metadata, stats: nil, nowMs: nowMs) == false
    )
    #expect(
        MemoryRetention.isQuarantineCandidate(metadata: metadata, stats: nil, nowMs: nowMs) == false
    )
}

@Test
func agedWorkingNotesAreQuarantineCandidates() {
    let nowMs: Int64 = 1_700_000_000_000
    let created = nowMs - 31 * 24 * 60 * 60 * 1000
    let metadata = [
        MemoryMetadataKeys.type: MemoryType.note.rawValue,
        MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
        MemoryMetadataKeys.createdAtMs: String(created),
    ]
    #expect(MemoryRetention.isQuarantineCandidate(metadata: metadata, stats: nil, nowMs: nowMs))
}

@Test
func coldTierIsHiddenFromDefaultHybridAndVisibleToText() {
    let nowMs: Int64 = 1_700_000_000_000
    let metadata = [
        MemoryMetadataKeys.type: MemoryType.decision.rawValue,
        MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
        MemoryMetadataKeys.tier: MemoryTier.cold.rawValue,
        MemoryMetadataKeys.createdAtMs: String(nowMs - 40 * 24 * 60 * 60 * 1000),
    ]
    #expect(
        MemoryRetention.isVisibleInDefaultRecall(
            metadata: metadata,
            stats: nil,
            nowMs: nowMs,
            query: "what should we never auto-delete",
            mode: .hybrid(alpha: 0.5)
        ) == false
    )
    #expect(
        MemoryRetention.isVisibleInDefaultRecall(
            metadata: metadata,
            stats: nil,
            nowMs: nowMs,
            query: "WAXCOLD-ZX9",
            mode: .textOnly
        )
    )
}

@Test
func legacyAccessStatsJSONMapsAccessCountOntoEngagement() throws {
    let json = """
    {
      "frameId": 7,
      "accessCount": 12,
      "lastAccessMs": 1700000000000,
      "firstAccessMs": 1690000000000
    }
    """
    let stats = try JSONDecoder().decode(FrameAccessStats.self, from: Data(json.utf8))
    #expect(stats.frameId == 7)
    #expect(stats.impressionCount == 12)
    #expect(stats.engagementCount == 12)
    #expect(stats.lastEngagementMs == 1_700_000_000_000)
    #expect(AccessFrequencyRanker.adjustment(stats: stats, nowMs: 1_700_000_000_000) > 0)
}

@Test
func retentionSettingsReadEnvSeconds() {
    let settings = MemoryRetentionSettings.fromEnvironment([
        "WAX_SESSION_RECENTLY_CLOSED_SECS": "60",
        "WAX_WORKING_QUARANTINE_SECS": "120",
        "WAX_KEEP_COLD_THRESHOLD": "0.4",
        "WAX_COLD_MIN_AGE_SECS": "30",
    ])
    #expect(settings.recentlyClosedMs == 60_000)
    #expect(settings.workingQuarantineMs == 120_000)
    #expect(settings.keepColdThreshold == 0.4)
    #expect(settings.coldMinAgeMs == 30_000)
}
