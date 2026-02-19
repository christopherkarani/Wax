import Foundation

/// Access statistics for a single frame.
public struct FrameAccessStats: Sendable, Equatable, Codable {
    /// Frame ID
    public var frameId: UInt64
    
    /// Total access count
    public var accessCount: UInt32
    
    /// Last access timestamp (milliseconds since epoch)
    public var lastAccessMs: Int64
    
    /// First access timestamp (milliseconds since epoch)
    public var firstAccessMs: Int64
    
    public init(frameId: UInt64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.frameId = frameId
        self.accessCount = 1
        self.lastAccessMs = nowMs
        self.firstAccessMs = nowMs
    }
    
    public mutating func recordAccess(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        // Use saturating addition to prevent overflow
        accessCount = accessCount.addingReportingOverflow(1).partialValue
        lastAccessMs = nowMs
    }
}

/// Manages access statistics for frame retrieval tracking.
public actor AccessStatsManager {
    private var stats: [UInt64: FrameAccessStats] = [:]
    private var dirty = false
    
    public init() {}
    
    /// Record a single frame access.
    public func recordAccess(frameId: UInt64) {
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
    public func recordAccesses(frameIds: [UInt64]) {
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
    public func getStats(frameId: UInt64) -> FrameAccessStats? {
        stats[frameId]
    }
    
    /// Get stats for multiple frames.
    public func getStats(frameIds: [UInt64]) -> [UInt64: FrameAccessStats] {
        var result: [UInt64: FrameAccessStats] = [:]
        result.reserveCapacity(frameIds.count)
        for frameId in frameIds {
            if let stat = stats[frameId] {
                result[frameId] = stat
            }
        }
        return result
    }
    
    /// Remove stats for frames that no longer exist.
    public func pruneStats(keepingOnly activeFrameIds: Set<UInt64>) {
        let before = stats.count
        stats = stats.filter { activeFrameIds.contains($0.key) }
        if stats.count != before {
            dirty = true
        }
    }
    
    /// Export all stats for persistence.
    public func exportStats() -> [FrameAccessStats] {
        Array(stats.values).sorted { $0.frameId < $1.frameId }
    }

    /// Export all stats only when they have changed since the last persist.
    public func exportStatsIfDirty() -> [FrameAccessStats]? {
        guard dirty else { return nil }
        return exportStats()
    }

    /// Mark the current in-memory snapshot as persisted.
    public func markPersisted() {
        dirty = false
    }
    
    /// Import stats from persistence.
    public func importStats(_ imported: [FrameAccessStats]) {
        stats = Dictionary(uniqueKeysWithValues: imported.map { ($0.frameId, $0) })
        dirty = false
    }
    
    /// Total number of tracked frames.
    public var count: Int {
        stats.count
    }
}
