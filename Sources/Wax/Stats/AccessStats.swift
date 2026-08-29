import Foundation

/// Access statistics for a single frame.
package struct FrameAccessStats: Sendable, Equatable, Codable {
    /// Frame ID
    package var frameId: UInt64

    /// Times the frame appeared in a retrieval result list.
    package var impressionCount: UInt32

    /// Times the frame was explicitly used (get/promote/compact short).
    package var engagementCount: UInt32

    /// Last impression timestamp (milliseconds since epoch)
    package var lastImpressionMs: Int64

    /// Last engagement timestamp (milliseconds since epoch)
    package var lastEngagementMs: Int64

    /// First access timestamp (milliseconds since epoch)
    package var firstAccessMs: Int64

    package var accessCount: UInt32 {
        get { impressionCount }
        set { impressionCount = newValue }
    }

    package var lastAccessMs: Int64 {
        get { lastImpressionMs }
        set { lastImpressionMs = newValue }
    }

    package init(frameId: UInt64, nowMs: Int64) {
        self.frameId = frameId
        self.impressionCount = 1
        self.engagementCount = 0
        self.lastImpressionMs = nowMs
        self.lastEngagementMs = 0
        self.firstAccessMs = nowMs
    }

    package init(
        frameId: UInt64,
        impressionCount: UInt32,
        engagementCount: UInt32,
        lastImpressionMs: Int64,
        lastEngagementMs: Int64,
        firstAccessMs: Int64
    ) {
        self.frameId = frameId
        self.impressionCount = impressionCount
        self.engagementCount = engagementCount
        self.lastImpressionMs = lastImpressionMs
        self.lastEngagementMs = lastEngagementMs
        self.firstAccessMs = firstAccessMs
    }

    package mutating func recordImpression(nowMs: Int64) {
        let (nextCount, overflowed) = impressionCount.addingReportingOverflow(1)
        impressionCount = overflowed ? UInt32.max : nextCount
        lastImpressionMs = nowMs
    }

    package mutating func recordEngagement(nowMs: Int64) {
        let (nextCount, overflowed) = engagementCount.addingReportingOverflow(1)
        engagementCount = overflowed ? UInt32.max : nextCount
        lastEngagementMs = nowMs
        lastImpressionMs = nowMs
        let (nextImpression, impressionOverflowed) = impressionCount.addingReportingOverflow(1)
        impressionCount = impressionOverflowed ? UInt32.max : nextImpression
    }

    package mutating func recordAccess(nowMs: Int64) {
        recordEngagement(nowMs: nowMs)
    }

    private enum CodingKeys: String, CodingKey {
        case frameId
        case impressionCount
        case engagementCount
        case lastImpressionMs
        case lastEngagementMs
        case firstAccessMs
        case accessCount
        case lastAccessMs
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameId = try container.decode(UInt64.self, forKey: .frameId)
        firstAccessMs = try container.decode(Int64.self, forKey: .firstAccessMs)
        if let impression = try container.decodeIfPresent(UInt32.self, forKey: .impressionCount) {
            impressionCount = impression
            engagementCount = try container.decodeIfPresent(UInt32.self, forKey: .engagementCount) ?? 0
            lastImpressionMs = try container.decodeIfPresent(Int64.self, forKey: .lastImpressionMs)
                ?? container.decodeIfPresent(Int64.self, forKey: .lastAccessMs)
                ?? firstAccessMs
            lastEngagementMs = try container.decodeIfPresent(Int64.self, forKey: .lastEngagementMs) ?? 0
        } else {
            let access = try container.decode(UInt32.self, forKey: .accessCount)
            let lastAccess = try container.decode(Int64.self, forKey: .lastAccessMs)
            impressionCount = access
            engagementCount = access
            lastImpressionMs = lastAccess
            lastEngagementMs = lastAccess
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameId, forKey: .frameId)
        try container.encode(impressionCount, forKey: .impressionCount)
        try container.encode(engagementCount, forKey: .engagementCount)
        try container.encode(lastImpressionMs, forKey: .lastImpressionMs)
        try container.encode(lastEngagementMs, forKey: .lastEngagementMs)
        try container.encode(firstAccessMs, forKey: .firstAccessMs)
    }
}

/// Manages access statistics for frame retrieval tracking.
package actor AccessStatsManager {
    private var stats: [UInt64: FrameAccessStats] = [:]
    private var dirty = false
    private var revision: UInt64 = 0

    package init() {}

    /// Record a single frame access (engagement).
    package func recordAccess(frameId: UInt64, nowMs: Int64) {
        recordEngagement(frameId: frameId, nowMs: nowMs)
    }

    package func recordImpression(frameId: UInt64, nowMs: Int64) {
        if var existing = stats[frameId] {
            existing.recordImpression(nowMs: nowMs)
            stats[frameId] = existing
        } else {
            stats[frameId] = FrameAccessStats(frameId: frameId, nowMs: nowMs)
        }
        dirty = true
        revision = revision == UInt64.max ? 0 : revision + 1
    }

    package func recordImpressions(frameIds: [UInt64], nowMs: Int64) {
        guard !frameIds.isEmpty else { return }
        for frameId in frameIds {
            if var existing = stats[frameId] {
                existing.recordImpression(nowMs: nowMs)
                stats[frameId] = existing
            } else {
                stats[frameId] = FrameAccessStats(frameId: frameId, nowMs: nowMs)
            }
        }
        dirty = true
        revision = revision == UInt64.max ? 0 : revision + 1
    }

    package func recordEngagement(frameId: UInt64, nowMs: Int64) {
        if var existing = stats[frameId] {
            existing.recordEngagement(nowMs: nowMs)
            stats[frameId] = existing
        } else {
            var created = FrameAccessStats(frameId: frameId, nowMs: nowMs)
            created.engagementCount = 1
            created.lastEngagementMs = nowMs
            stats[frameId] = created
        }
        dirty = true
        revision = revision == UInt64.max ? 0 : revision + 1
    }

    /// Record accesses for multiple frames at once (engagement).
    package func recordAccesses(frameIds: [UInt64], nowMs: Int64) {
        guard !frameIds.isEmpty else { return }
        for frameId in frameIds {
            recordEngagement(frameId: frameId, nowMs: nowMs)
        }
    }

    package func seedStats(_ imported: FrameAccessStats, for frameId: UInt64) {
        var copy = imported
        copy.frameId = frameId
        stats[frameId] = copy
        dirty = true
        revision = revision == UInt64.max ? 0 : revision + 1
    }

    /// Get stats for a single frame.
    package func getStats(frameId: UInt64) -> FrameAccessStats? {
        stats[frameId]
    }

    /// Get stats for multiple frames.
    package func getStats(frameIds: [UInt64]) -> [UInt64: FrameAccessStats] {
        var result: [UInt64: FrameAccessStats] = [:]
        result.reserveCapacity(frameIds.count)
        for frameId in frameIds {
            if let stat = stats[frameId] {
                result[frameId] = stat
            }
        }
        return result
    }

    package func snapshot() -> [UInt64: FrameAccessStats] {
        stats
    }

    /// Remove stats for frames that no longer exist.
    package func pruneStats(keepingOnly activeFrameIds: Set<UInt64>) {
        let before = stats.count
        stats = stats.filter { activeFrameIds.contains($0.key) }
        if stats.count != before {
            dirty = true
            revision = revision == UInt64.max ? 0 : revision + 1
        }
    }

    /// Export all stats for persistence.
    package func exportStats() -> [FrameAccessStats] {
        Array(stats.values).sorted { $0.frameId < $1.frameId }
    }

    /// Export all stats only when they have changed since the last persist.
    package func exportStatsIfDirty() -> [FrameAccessStats]? {
        guard dirty else { return nil }
        return exportStats()
    }

    /// Return a dirty snapshot together with the revision observed at the
    /// snapshot boundary. Persistence can then acknowledge only that exact
    /// revision, preserving accesses recorded while the store write awaited.
    package func exportStatsSnapshotIfDirty() -> (stats: [FrameAccessStats], revision: UInt64)? {
        guard dirty else { return nil }
        return (exportStats(), revision)
    }

    /// Mark the current in-memory snapshot as persisted.
    package func markPersisted() {
        dirty = false
    }

    /// Clear the dirty bit only when no newer access mutation occurred after
    /// the persisted snapshot was taken.
    @discardableResult
    package func markPersisted(ifRevision snapshotRevision: UInt64) -> Bool {
        guard revision == snapshotRevision else { return false }
        dirty = false
        return true
    }

    /// Import stats from persistence.
    package func importStats(_ imported: [FrameAccessStats]) {
        stats = Dictionary(uniqueKeysWithValues: imported.map { ($0.frameId, $0) })
        dirty = false
        revision = revision == UInt64.max ? 0 : revision + 1
    }

    /// Total number of tracked frames.
    package var count: Int {
        stats.count
    }
}
