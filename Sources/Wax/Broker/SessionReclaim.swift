import Foundation

package struct SessionDiskStats: Sendable, Equatable {
    package var rootPath: String
    package var active: Int
    package var ended: Int
    package var zombies: Int
    package var recentlyClosed: Int
    package var reclaimable: Int
    package var apparentBytes: UInt64
    package var actualBytes: UInt64
    package var reclaimableBytes: UInt64
    package var reclaimableSessionIDs: [UUID]

    package func asBrokerValue() -> AgentBrokerValue {
        .object([
            "root_path": .string(rootPath),
            "active": .from(active),
            "ended": .from(ended),
            "zombies": .from(zombies),
            "recently_closed": .from(recentlyClosed),
            "reclaimable": .from(reclaimable),
            "apparent_bytes": .from(apparentBytes),
            "actual_bytes": .from(actualBytes),
            "reclaimable_bytes": .from(reclaimableBytes),
        ])
    }
}

package enum SessionReclaim {
    package static func isZombie(
        manifest: BrokerSessionManifest,
        liveIDs: Set<UUID>,
        nowMs: Int64
    ) -> Bool {
        guard manifest.status == .active else { return false }
        guard !liveIDs.contains(manifest.sessionID) else { return false }
        guard let lease = manifest.leaseExpiresAtMs else { return false }
        return lease < nowMs
    }

    package static func isRecentlyClosed(
        manifest: BrokerSessionManifest,
        nowMs: Int64
    ) -> Bool {
        guard manifest.status == .ended, manifest.reclaimedAtMs == nil else { return false }
        guard let reclaimAfterMs = manifest.reclaimAfterMs else { return false }
        return nowMs < reclaimAfterMs && FileManager.default.fileExists(atPath: manifest.storePath)
    }

    package static func isReclaimable(
        manifest: BrokerSessionManifest,
        nowMs: Int64,
        force: Bool = false
    ) -> Bool {
        guard manifest.status == .ended else { return false }
        guard manifest.reclaimedAtMs == nil else { return false }
        guard FileManager.default.fileExists(atPath: manifest.storePath) else { return false }
        if force {
            return true
        }
        if manifest.harvestError != nil {
            return false
        }
        guard let reclaimAfterMs = manifest.reclaimAfterMs else { return false }
        return nowMs >= reclaimAfterMs
    }

    package static func diskStats(
        rootURL: URL,
        manifests: [BrokerSessionManifest],
        liveIDs: Set<UUID>,
        nowMs: Int64
    ) -> SessionDiskStats {
        var active = 0
        var ended = 0
        var zombies = 0
        var recentlyClosed = 0
        var reclaimableIDs: [UUID] = []
        var reclaimableBytes: UInt64 = 0

        for manifest in manifests {
            if isZombie(manifest: manifest, liveIDs: liveIDs, nowMs: nowMs) {
                zombies += 1
                reclaimableBytes += MemoryRetention.fileApparentBytes(at: manifest.storePath)
            } else if manifest.status == .active {
                active += 1
            } else {
                ended += 1
                if isRecentlyClosed(manifest: manifest, nowMs: nowMs) {
                    recentlyClosed += 1
                }
                if isReclaimable(manifest: manifest, nowMs: nowMs) {
                    reclaimableIDs.append(manifest.sessionID)
                    reclaimableBytes += MemoryRetention.fileApparentBytes(at: manifest.storePath)
                }
            }
        }

        var apparent: UInt64 = 0
        var actual: UInt64 = 0
        if let items = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in items {
                apparent += MemoryRetention.fileApparentBytes(at: url.path)
                actual += MemoryRetention.fileActualBytes(at: url.path) ?? MemoryRetention.fileApparentBytes(at: url.path)
            }
        }

        return SessionDiskStats(
            rootPath: rootURL.path,
            active: active,
            ended: ended,
            zombies: zombies,
            recentlyClosed: recentlyClosed,
            reclaimable: reclaimableIDs.count,
            apparentBytes: apparent,
            actualBytes: actual,
            reclaimableBytes: reclaimableBytes,
            reclaimableSessionIDs: reclaimableIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    package static func unlink(
        manifest: BrokerSessionManifest,
        sessionRootURL: URL,
        nowMs: Int64
    ) throws -> BrokerSessionManifest {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: manifest.storePath) {
            try fileManager.removeItem(atPath: manifest.storePath)
        }
        if fileManager.fileExists(atPath: manifest.eventLogPath) {
            try fileManager.removeItem(atPath: manifest.eventLogPath)
        }
        var tombstone = manifest
        tombstone.status = .ended
        tombstone.storePath = ""
        tombstone.reclaimedAtMs = nowMs
        tombstone.updatedAtMs = nowMs
        tombstone.brokerLeaseOwnerID = nil
        tombstone.leaseExpiresAtMs = nil
        try BrokerSessionPersistence.saveManifest(
            tombstone,
            to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: manifest.sessionID)
        )
        return tombstone
    }
}
