import Foundation
import Testing
@testable import Wax

@Suite("SessionStartupMaintainTests")
struct SessionStartupMaintainTests {
    @Test
    func sessionReclaimTreatsFreshExpiredLeaseAsZombieNotAbandoned() {
        let nowMs: Int64 = 1_700_000_000_000
        let recentlyClosedMs = MemoryRetentionSettings.default.recentlyClosedMs
        let sessionID = UUID()

        let fresh = reclaimProbeManifest(
            sessionID: sessionID,
            status: .active,
            leaseExpiresAtMs: nowMs - 1
        )
        #expect(SessionReclaim.isZombie(manifest: fresh, liveIDs: [], nowMs: nowMs))
        #expect(SessionReclaim.isAbandonedZombie(manifest: fresh, liveIDs: [], nowMs: nowMs) == false)
        #expect(SessionReclaim.isAbandonedZombie(
            manifest: fresh,
            liveIDs: [],
            nowMs: nowMs,
            recentlyClosedMs: recentlyClosedMs
        ) == false)

        let atThreshold = reclaimProbeManifest(
            sessionID: sessionID,
            status: .active,
            leaseExpiresAtMs: nowMs - recentlyClosedMs
        )
        #expect(SessionReclaim.isZombie(manifest: atThreshold, liveIDs: [], nowMs: nowMs))
        #expect(SessionReclaim.isAbandonedZombie(
            manifest: atThreshold,
            liveIDs: [],
            nowMs: nowMs,
            recentlyClosedMs: recentlyClosedMs
        ))

        let abandoned = reclaimProbeManifest(
            sessionID: sessionID,
            status: .active,
            leaseExpiresAtMs: nowMs - recentlyClosedMs - 86_400_000
        )
        #expect(SessionReclaim.isZombie(manifest: abandoned, liveIDs: [], nowMs: nowMs))
        #expect(SessionReclaim.isAbandonedZombie(manifest: abandoned, liveIDs: [], nowMs: nowMs))

        #expect(SessionReclaim.isAbandonedZombie(
            manifest: abandoned,
            liveIDs: [sessionID],
            nowMs: nowMs
        ) == false)

        let ended = reclaimProbeManifest(
            sessionID: sessionID,
            status: .ended,
            leaseExpiresAtMs: nowMs - recentlyClosedMs - 86_400_000
        )
        #expect(SessionReclaim.isZombie(manifest: ended, liveIDs: [], nowMs: nowMs) == false)
        #expect(SessionReclaim.isAbandonedZombie(manifest: ended, liveIDs: [], nowMs: nowMs) == false)
    }

    @Test
    func brokerInitPreservesExpiredLeaseUntilExplicitMaintenance() async throws {
        try await withStartupGCRoots { storeURL, sessionRootURL in
            let sessionID = UUID()
            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { service in
                let started = await service.handle(.init(command: "session_start", arguments: [
                    "session_id": .string(sessionID.uuidString),
                    "project": .string("startup-gc"),
                ]))
                #expect(started.ok)
            }

            var before = try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: sessionID
            )
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            before.leaseExpiresAtMs = nowMs - 1_000
            try BrokerSessionPersistence.saveManifest(
                before,
                to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
            )
            #expect(before.status == .active)
            #expect(SessionReclaim.isZombie(
                manifest: before,
                liveIDs: [],
                nowMs: nowMs
            ))
            #expect(SessionReclaim.isAbandonedZombie(
                manifest: before,
                liveIDs: [],
                nowMs: nowMs
            ) == false)

            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { service in
                let preserved = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: sessionID
                )
                #expect(preserved.status == .active)
                #expect(preserved.harvestedAtMs == nil)
                let applied = await service.handle(.init(
                    command: "memory_maintain",
                    arguments: ["apply": .bool(true)]
                ))
                #expect(applied.ok)
                #expect(applied.payload?.objectValue?["zombies_to_end"]?.intValue == 1)
                let after = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: sessionID
                )
                #expect(after.status == .ended)
                #expect(after.harvestedAtMs != nil)
                #expect(after.harvestError == nil)
                #expect(SessionReclaim.isZombie(
                    manifest: after,
                    liveIDs: [],
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                ) == false)
            }
        }
    }

    @Test
    func brokerInitUnlinksReclaimableEndedSessionAndKeepsRecentlyClosedWithoutForce() async throws {
        try await withStartupGCRoots { storeURL, sessionRootURL in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let reclaimableID = UUID()
            let recentID = UUID()
            let blockedID = UUID()
            let reclaimablePath = try plantSessionManifest(
                sessionID: reclaimableID,
                sessionRootURL: sessionRootURL,
                status: .ended,
                harvestedAtMs: 1,
                reclaimAfterMs: 1
            )
            let recentPath = try plantSessionManifest(
                sessionID: recentID,
                sessionRootURL: sessionRootURL,
                status: .ended,
                harvestedAtMs: nowMs,
                reclaimAfterMs: nowMs + 604_800_000
            )
            let blockedPath = try plantSessionManifest(
                sessionID: blockedID,
                sessionRootURL: sessionRootURL,
                status: .ended,
                harvestedAtMs: 1,
                reclaimAfterMs: 1,
                harvestError: "harvest failed",
                storeContents: Data("not-a-wax-store".utf8)
            )

            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { _ in
                #expect(FileManager.default.fileExists(atPath: reclaimablePath) == false)
                let reclaimed = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: reclaimableID
                )
                #expect(reclaimed.status == .ended)
                #expect(reclaimed.reclaimedAtMs != nil)

                #expect(FileManager.default.fileExists(atPath: recentPath))
                let recent = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: recentID
                )
                #expect(recent.status == .ended)
                #expect(recent.reclaimedAtMs == nil)

                #expect(FileManager.default.fileExists(atPath: blockedPath))
                let blocked = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: blockedID
                )
                #expect(blocked.status == .ended)
                #expect(blocked.reclaimedAtMs == nil)
                #expect(blocked.harvestError != nil)
            }
        }
    }

    @Test
    func brokerInitHarvestsAbandonedZombieWhilePreservingFreshExpiredLease() async throws {
        try await withStartupGCRoots { storeURL, sessionRootURL in
            let freshID = UUID()
            let abandonedID = UUID()
            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { service in
                for sessionID in [freshID, abandonedID] {
                    let started = await service.handle(.init(command: "session_start", arguments: [
                        "session_id": .string(sessionID.uuidString),
                        "project": .string("startup-gc"),
                    ]))
                    #expect(started.ok)
                }
            }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let recentlyClosedMs = MemoryRetentionSettings.default.recentlyClosedMs

            var fresh = try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: freshID
            )
            fresh.leaseExpiresAtMs = nowMs - 1_000
            try BrokerSessionPersistence.saveManifest(
                fresh,
                to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: freshID)
            )
            #expect(fresh.status == .active)
            #expect(SessionReclaim.isZombie(manifest: fresh, liveIDs: [], nowMs: nowMs))
            #expect(SessionReclaim.isAbandonedZombie(manifest: fresh, liveIDs: [], nowMs: nowMs) == false)

            var abandoned = try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: abandonedID
            )
            abandoned.leaseExpiresAtMs = nowMs - recentlyClosedMs - 86_400_000
            try BrokerSessionPersistence.saveManifest(
                abandoned,
                to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: abandonedID)
            )
            #expect(abandoned.status == .active)
            #expect(SessionReclaim.isAbandonedZombie(manifest: abandoned, liveIDs: [], nowMs: nowMs))

            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { _ in
                let preserved = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: freshID
                )
                #expect(preserved.status == .active)
                #expect(preserved.harvestedAtMs == nil)

                let harvested = try BrokerSessionPersistence.loadManifest(
                    rootURL: sessionRootURL,
                    sessionID: abandonedID
                )
                #expect(harvested.status == .ended)
                #expect(harvested.harvestedAtMs != nil)
                #expect(harvested.harvestError == nil)
                #expect(SessionReclaim.isZombie(
                    manifest: harvested,
                    liveIDs: [],
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                ) == false)
            }
        }
    }
}

func withStartupGCRoots(
    _ body: (URL, URL) async throws -> Void
) async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-startup-gc-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionRootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try await body(storeURL, sessionRootURL)
}

func withStartupBroker(
    storePath: String,
    sessionRootPath: String,
    _ body: (AgentBrokerService) async throws -> Void
) async throws {
    let service = try await AgentBrokerService(
        storePath: storePath,
        sessionRootPath: sessionRootPath,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        try await body(service)
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}

@discardableResult
func plantSessionManifest(
    sessionID: UUID,
    sessionRootURL: URL,
    status: BrokerSessionManifest.Status,
    leaseExpiresAtMs: Int64? = nil,
    brokerLeaseOwnerID: String? = nil,
    harvestedAtMs: Int64? = nil,
    reclaimAfterMs: Int64? = nil,
    harvestError: String? = nil,
    storeContents: Data = Data()
) throws -> String {
    let storePath = sessionRootURL.appendingPathComponent("\(sessionID.uuidString).wax").path
    FileManager.default.createFile(atPath: storePath, contents: storeContents)
    let manifest = BrokerSessionManifest(
        sessionID: sessionID,
        agentID: "startup-gc-agent",
        runID: "startup-gc-run-\(sessionID.uuidString.prefix(8))",
        project: "startup-gc",
        repo: "startup-gc",
        storePath: storePath,
        eventLogPath: BrokerSessionPersistence.eventLogURL(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ).path,
        status: status,
        brokerLeaseOwnerID: brokerLeaseOwnerID,
        leaseExpiresAtMs: leaseExpiresAtMs,
        createdAtMs: 1,
        updatedAtMs: 1,
        endedAtMs: status == .ended ? 1 : nil,
        harvestedAtMs: harvestedAtMs,
        reclaimAfterMs: reclaimAfterMs,
        harvestError: harvestError
    )
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
    )
    return storePath
}

private func reclaimProbeManifest(
    sessionID: UUID,
    status: BrokerSessionManifest.Status,
    leaseExpiresAtMs: Int64?
) -> BrokerSessionManifest {
    BrokerSessionManifest(
        sessionID: sessionID,
        agentID: "startup-gc-agent",
        runID: "startup-gc-run",
        project: "startup-gc",
        repo: "startup-gc",
        storePath: "/tmp/startup-gc-missing.wax",
        eventLogPath: "/tmp/startup-gc-missing.jsonl",
        status: status,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: leaseExpiresAtMs,
        createdAtMs: 1,
        updatedAtMs: 1
    )
}
