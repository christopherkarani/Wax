import Foundation

/// Access statistics for a single frame.
package struct FrameAccessStats: Sendable, Equatable, Codable {
    /// Frame ID
    package var frameId: UInt64
    
    /// Total access count
    package var accessCount: UInt32
    
    /// Last access timestamp (milliseconds since epoch)
    package var lastAccessMs: Int64
    
    /// First access timestamp (milliseconds since epoch)
    package var firstAccessMs: Int64
    
    package init(frameId: UInt64, nowMs: Int64) {
        self.frameId = frameId
        self.accessCount = 1
        self.lastAccessMs = nowMs
        self.firstAccessMs = nowMs
    }

    package mutating func recordAccess(nowMs: Int64) {
        // Use saturating addition to prevent overflow
        let (nextCount, overflowed) = accessCount.addingReportingOverflow(1)
        accessCount = overflowed ? UInt32.max : nextCount
        lastAccessMs = nowMs
    }
}

/// Manages access statistics for frame retrieval tracking.
package actor AccessStatsManager {
    private var stats: [UInt64: FrameAccessStats] = [:]
    private var dirty = false
    private var revision: UInt64 = 0

    package init() {}

    /// Record a single frame access.
    package func recordAccess(frameId: UInt64, nowMs: Int64) {
        if var existing = stats[frameId] {
            existing.recordAccess(nowMs: nowMs)
            stats[frameId] = existing
        } else {
            stats[frameId] = FrameAccessStats(frameId: frameId, nowMs: nowMs)
        }
        dirty = true
        revision = revision == UInt64.max ? 0 : revision + 1
    }

    /// Record accesses for multiple frames at once.
    package func recordAccesses(frameIds: [UInt64], nowMs: Int64) {
        guard !frameIds.isEmpty else { return }
        for frameId in frameIds {
            if var existing = stats[frameId] {
                existing.recordAccess(nowMs: nowMs)
                stats[frameId] = existing
            } else {
                stats[frameId] = FrameAccessStats(frameId: frameId, nowMs: nowMs)
            }
        }
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
