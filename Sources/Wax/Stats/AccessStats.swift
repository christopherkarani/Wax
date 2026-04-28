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
    
    package init(frameId: UInt64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.frameId = frameId
        self.accessCount = 1
        self.lastAccessMs = nowMs
        self.firstAccessMs = nowMs
    }
    
    package mutating func recordAccess(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        // Use saturating addition to prevent overflow
        accessCount = accessCount.addingReportingOverflow(1).partialValue
        lastAccessMs = nowMs
    }
}

/// Manages access statistics for frame retrieval tracking.
package actor AccessStatsManager {
    private var stats: [UInt64: FrameAccessStats] = [:]
    private var dirty = false
    
    package init() {}
    
    /// Record a single frame access.
    package func recordAccess(frameId: UInt64) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if var existing = stats[frameId] {
            existing.recordAccess(nowMs: nowMs)
            stats[frameId] = existing
        } else {
            stats[frameId] = FrameAccessStats(frameId: frameId, nowMs: nowMs)
        }
        dirty = true
    }
    
    /// Record accesses for multiple frames at once.
    package func recordAccesses(frameIds: [UInt64]) {
        guard !frameIds.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for frameId in frameIds {
            if var existing = stats[frameId] {
                existing.recordAccess(nowMs: nowMs)
                stats[frameId] = existing
            } else {
                stats[frameId] = FrameAccessStats(frameId: frameId, nowMs: nowMs)
            }
        }
        dirty = true
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

    /// Mark the current in-memory snapshot as persisted.
    package func markPersisted() {
        dirty = false
    }
    
    /// Import stats from persistence.
    package func importStats(_ imported: [FrameAccessStats]) {
        stats = Dictionary(uniqueKeysWithValues: imported.map { ($0.frameId, $0) })
        dirty = false
    }
    
    /// Total number of tracked frames.
    package var count: Int {
        stats.count
    }
}
