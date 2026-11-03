import Foundation
import WaxCore

extension VirtualSessionStore {
    /// Returns the on-disk manifest status for `sessionID`, or `nil` if no manifest exists.
    package func persistedStatus(for sessionID: UUID) throws -> BrokerSessionManifest.Status? {
        do {
            return try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: sessionID
            ).status
        } catch BrokerSessionPersistenceError.manifestNotFound {
            return nil
        }
    }

    package func resolveManifest(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?
    ) throws -> BrokerSessionManifest {
        if let explicitSessionID {
            return try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: explicitSessionID)
        }

        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
        let filtered = manifests.filter { manifest in
            guard manifest.status == .active else { return false }
            if let agentID, manifest.agentID != agentID { return false }
            if let runID, manifest.runID != runID { return false }
            return true
        }
        guard filtered.count <= 1 else {
            throw BrokerValidationError.invalid("multiple active sessions matched the requested selectors")
        }
        guard let match = filtered.first else {
            throw BrokerValidationError.invalid("No resumable session manifest matched the requested selectors")
        }
        return match
    }

    package func persistHarvestToDisk(
        sessionID: UUID,
        report: SessionHarvest.Report,
        markEnded: Bool,
        nowMs: Int64? = nil
    ) throws -> BrokerSessionManifest {
        let timestamp = nowMs ?? self.nowMs()
        var manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        if markEnded, manifest.status != .ended {
            manifest.status = .ended
            manifest.endedAtMs = timestamp
            manifest.brokerLeaseOwnerID = nil
            manifest.leaseExpiresAtMs = nil
        }
        manifest.updatedAtMs = timestamp
        Self.applyHarvest(report, to: &manifest, nowMs: timestamp)
        try BrokerSessionPersistence.saveManifest(
            manifest,
            to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        )
        return manifest
    }

    package static func applyHarvest(
        _ report: SessionHarvest.Report,
        to manifest: inout BrokerSessionManifest,
        nowMs: Int64
    ) {
        if report.harvested {
            manifest.harvestError = (report.error?.isEmpty == false) ? report.error : nil
            if manifest.harvestedAtMs == nil {
                manifest.harvestedAtMs = nowMs
            }
            manifest.promotedCount = report.promotedCount
            if report.immediateReclaimEligible {
                manifest.reclaimAfterMs = manifest.harvestedAtMs
            } else if let reclaimAfterMs = report.reclaimAfterMs {
                manifest.reclaimAfterMs = reclaimAfterMs
            }
            return
        }
        if let error = report.error, !error.isEmpty {
            manifest.harvestError = error
        }
    }
}
