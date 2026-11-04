import Foundation
import Testing
@testable import Wax

// Regressions for `try?` sites that turned a read failure into a clean-looking result.

private let auditProject = "try-audit"

private struct AuditRoots {
    let root: URL
    let store: URL
    let sessions: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-try-audit-\(UUID().uuidString)", isDirectory: true)
        store = root.appendingPathComponent("memory.wax")
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeService() async throws -> AgentBrokerService {
        try await AgentBrokerService(
            storePath: store.path,
            sessionRootPath: sessions.path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )
    }
}

private func withService<T>(
    _ roots: AuditRoots,
    _ body: (AgentBrokerService) async throws -> T
) async throws -> T {
    let service = try await roots.makeService()
    do {
        let result = try await body(service)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func startSession(_ service: AgentBrokerService, runID: String) async throws -> UUID {
    let started = await service.handle(.init(
        command: "session_start",
        arguments: [
            "agent_id": .string("try-audit-agent"),
            "run_id": .string(runID),
            "project": .string(auditProject),
            "repo": .string(auditProject),
        ]
    ))
    #expect(started.ok == true, "session_start failed: \(started.error ?? "nil")")
    let raw = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
    return try #require(UUID(uuidString: raw))
}

private func rememberDecision(_ service: AgentBrokerService, sessionID: UUID, content: String) async {
    let write = await service.handle(.init(
        command: "remember",
        arguments: [
            "content": .string(content),
            "session_id": .string(sessionID.uuidString),
            "memory_type": .string("decision"),
            "durability": .string("working"),
            "scope": .string("session"),
            "project": .string(auditProject),
            "repo": .string(auditProject),
        ]
    ))
    #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
}

/// Makes `url` write-only. Returns false when the process can still read it
/// (a privileged runner), in which case the caller has nothing to prove.
private func makeWriteOnly(_ url: URL) throws -> Bool {
    try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
    return (try? Data(contentsOf: url)) == nil
}

private func restoreReadable(_ url: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@Test
func sessionEndWithUnreadableEventLogRecordsHarvestErrorInsteadOfCleanHarvest() async throws {
    let roots = try AuditRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }

    try await withService(roots) { service in
        let sessionID = try await startSession(service, runID: "unreadable-events-end")
        await rememberDecision(service, sessionID: sessionID, content: "Decision: keep WAXTRYEND as a token.")
        let eventLog = BrokerSessionPersistence.eventLogURL(rootURL: roots.sessions, sessionID: sessionID)
        #expect(FileManager.default.fileExists(atPath: eventLog.path))
        defer { restoreReadable(eventLog) }
        guard try makeWriteOnly(eventLog) else { return }

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID.uuidString)]
        ))
        #expect(ended.ok == true, "session_end failed: \(ended.error ?? "nil")")
        let payload = try #require(ended.payload?.objectValue)
        #expect(payload["harvested"]?.boolValue == false)
        #expect(payload["harvest_error"]?.stringValue?.contains("event log") == true)

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: roots.sessions, sessionID: sessionID)
        #expect(manifest.harvestedAtMs == nil)
        #expect(manifest.harvestError != nil)
        #expect(!SessionReclaim.isReclaimable(manifest: manifest, nowMs: Int64.max))
    }
}

@Test
func maintainHarvestWithUnreadableEventLogKeepsSessionStoreForRetry() async throws {
    let roots = try AuditRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }

    let sessionID = try await withService(roots) { service in
        let sessionID = try await startSession(service, runID: "unreadable-events-maintain")
        await rememberDecision(service, sessionID: sessionID, content: "Decision: keep WAXTRYZMB as a token.")
        return sessionID
    }

    var manifest = try BrokerSessionPersistence.loadManifest(rootURL: roots.sessions, sessionID: sessionID)
    manifest.leaseExpiresAtMs = 1
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: roots.sessions, sessionID: sessionID)
    )
    let eventLog = BrokerSessionPersistence.eventLogURL(rootURL: roots.sessions, sessionID: sessionID)
    defer { restoreReadable(eventLog) }
    guard try makeWriteOnly(eventLog) else { return }
    let storeURL = URL(fileURLWithPath: manifest.storePath)

    try await withService(roots) { service in
        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "maintain failed: \(applied.error ?? "nil")")
    }

    let after = try BrokerSessionPersistence.loadManifest(rootURL: roots.sessions, sessionID: sessionID)
    #expect(after.status == .ended)
    #expect(after.harvestedAtMs == nil)
    #expect(after.harvestError?.contains("event log") == true)
    #expect(FileManager.default.fileExists(atPath: storeURL.path))
}

@Test
func taskStateMigrationFailsWhenProvenanceManifestIsUnreadable() async throws {
    let roots = try AuditRoots()
    defer { try? FileManager.default.removeItem(at: roots.root) }

    try await withService(roots) { service in
        let sessionID = try await startSession(service, runID: "unreadable-provenance")
        try await service.longTermMemory.remember(
            "task state whose session still exists",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.taskState.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                "session_id": sessionID.uuidString,
            ]
        )
        try await service.longTermMemory.flush()

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: roots.sessions, sessionID: sessionID)
        defer { restoreReadable(manifestURL) }
        guard try makeWriteOnly(manifestURL) else { return }

        let destination = roots.root.appendingPathComponent("repaired-drop.wax")
        let migrated = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(destination.path),
                "orphan_policy": .string("drop"),
            ]
        ))
        // An unreadable manifest is not proof the session is gone; dropping the
        // record would silently lose task state that still has a home.
        #expect(migrated.ok == false)
        #expect(migrated.payload?.objectValue?["dropped_document_count"]?.intValue == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
