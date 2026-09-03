import Foundation
import Testing
@testable import Wax

@Test
func brokerInitEndsZombieExpiredLeaseTheSameWayMaintainWould() async throws {
    try await withStartupGCRoots { storeURL, sessionRootURL in
        let sessionID = UUID()
        _ = try plantSessionManifest(
            sessionID: sessionID,
            sessionRootURL: sessionRootURL,
            status: .active,
            leaseExpiresAtMs: 1,
            brokerLeaseOwnerID: "dead-broker"
        )

        let before = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        )
        #expect(before.status == .active)
        #expect(SessionReclaim.isZombie(
            manifest: before,
            liveIDs: [],
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))

        try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { _ in
            let after = try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: sessionID
            )
            #expect(after.status == .ended)
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

private func withStartupGCRoots(
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

private func withStartupBroker(
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
private func plantSessionManifest(
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
