import Foundation
import Testing
@testable import Wax

private let harvestProject = "harvest-qa"

private func withHarvestBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-harvest-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, sessionRootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

private func requireString(_ object: [String: AgentBrokerValue], _ key: String) throws -> String {
    try #require(object[key]?.stringValue)
}

private func firstHitText(_ payload: [String: AgentBrokerValue]) -> String {
    let first = payload["results"]?.arrayValue?.first?.objectValue
    return first?["text"]?.stringValue
        ?? first?["preview"]?.stringValue
        ?? ""
}

private func startHarvestSession(
    _ service: AgentBrokerService,
    runID: String
) async throws -> String {
    let started = await service.handle(.init(
        command: "session_start",
        arguments: [
            "agent_id": .string("harvest-agent"),
            "run_id": .string(runID),
            "project": .string(harvestProject),
            "repo": .string(harvestProject),
        ]
    ))
    #expect(started.ok == true, "session_start failed: \(started.error ?? "nil")")
    return try requireString(try requireObject(started.payload), "session_id")
}

private func rememberSession(
    _ service: AgentBrokerService,
    sessionID: String,
    content: String,
    memoryType: String,
    durability: String = "working"
) async throws {
    let write = await service.handle(.init(
        command: "remember",
        arguments: [
            "content": .string(content),
            "session_id": .string(sessionID),
            "memory_type": .string(memoryType),
            "durability": .string(durability),
            "scope": .string("session"),
            "project": .string(harvestProject),
            "repo": .string(harvestProject),
        ]
    ))
    #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
}

private func endSession(_ service: AgentBrokerService, sessionID: String) async throws -> [String: AgentBrokerValue] {
    let ended = await service.handle(.init(
        command: "session_end",
        arguments: ["session_id": .string(sessionID)]
    ))
    #expect(ended.ok == true, "session_end failed: \(ended.error ?? "nil")")
    return try requireObject(ended.payload)
}

private func projectRecall(
    _ service: AgentBrokerService,
    query: String,
    mode: String = "text"
) async throws -> [String: AgentBrokerValue] {
    let recall = await service.handle(.init(
        command: "recall",
        arguments: [
            "query": .string(query),
            "mode": .string(mode),
            "scope": .string("project"),
            "project": .string(harvestProject),
            "repo": .string(harvestProject),
            "limit": .int(8),
        ]
    ))
    #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
    return try requireObject(recall.payload)
}

private func sessionStoreURL(root: URL, sessionID: String) -> URL {
    root.appendingPathComponent("\(sessionID).wax")
}

private func liveHarvestState(
    _ service: AgentBrokerService,
    sessionID: String
) async throws -> VirtualSessionStore.SessionState {
    let uuid = try #require(UUID(uuidString: sessionID))
    return try #require(await service.activeSessions[uuid])
}

private func harvestLiveSession(
    _ service: AgentBrokerService,
    sessionID: String
) async throws -> SessionHarvest.Report {
    let state = try await liveHarvestState(service, sessionID: sessionID)
    let events = (try? BrokerSessionPersistence.loadEvents(from: state.eventLogURL)) ?? []
    return await SessionHarvest.run(
        sessionMemory: state.memory,
        longTermMemory: service.longTermMemory,
        sessionID: state.id,
        manifest: state.manifest,
        events: events,
        scope: MemoryScopeContext(repoName: harvestProject, projectName: harvestProject),
        retention: .default,
        nowMs: BrokerClock.nowMs()
    )
}

@Test
func sessionCloseHarvestsAlwaysPromotableNeedleIntoDurableRecall() async throws {
    let needle = "WAXHVST-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, sessionRoot in
        let sessionID = try await startHarvestSession(service, runID: "harvest-needle")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Decision: keep \(needle) as the harvest gold token.",
            memoryType: "decision"
        )
        for index in 0..<8 {
            try await rememberSession(
                service,
                sessionID: sessionID,
                content: "Working distractor \(index) about ranking noise without the gold token.",
                memoryType: "note"
            )
        }

        let ended = try await endSession(service, sessionID: sessionID)
        #expect(ended["harvested"]?.boolValue == true)
        #expect((ended["promoted_count"]?.intValue ?? 0) >= 1)
        #expect(ended["reclaimed"]?.boolValue == false)
        #expect(FileManager.default.fileExists(atPath: sessionStoreURL(root: sessionRoot, sessionID: sessionID).path))

        let payload = try await projectRecall(service, query: needle)
        #expect(
            firstHitText(payload).contains(needle),
            "durable recall missed harvested needle; top=\(firstHitText(payload))"
        )
        #expect(payload["results"]?.arrayValue?.contains { result in
            result.objectValue?["text"]?.stringValue?.contains("Working distractor") == true
        } != true)
    }
}

@Test
func emptyPromotableSessionIsReclaimedByMaintainWithoutWaiting() async throws {
    let needle = "WAXHVIM-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, sessionRoot in
        let sessionID = try await startHarvestSession(service, runID: "harvest-immediate")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Decision: \(needle) is the only session fact.",
            memoryType: "decision"
        )
        let ended = try await endSession(service, sessionID: sessionID)
        #expect(ended["harvested"]?.boolValue == true)
        #expect(ended["reclaimed"]?.boolValue != true)
        let storePath = sessionStoreURL(root: sessionRoot, sessionID: sessionID).path
        #expect(FileManager.default.fileExists(atPath: storePath))

        let manifest = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRoot,
            sessionID: UUID(uuidString: sessionID)!
        )
        #expect(manifest.status == .ended)
        #expect(manifest.reclaimAfterMs == manifest.harvestedAtMs)

        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "immediate maintain reclaim failed: \(applied.error ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: storePath))

        let payload = try await projectRecall(service, query: needle)
        #expect(firstHitText(payload).contains(needle))
    }
}

@Test
func closeDoesNotPromoteImplicitMustNotesIntoDurableRecall() async throws {
    let token = "ENDED-WORKING-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-implicit-note")
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Ended-session working note \(token) must not leak unscoped."),
                "session_id": .string(sessionID),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
            ]
        ))
        #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
        _ = try await endSession(service, sessionID: sessionID)

        let payload = try await projectRecall(service, query: token)
        #expect(!firstHitText(payload).contains(token))
    }
}

@Test
func secondCloseIsIdempotentAndDoesNotDuplicateHarvest() async throws {
    let needle = "WAXHVID-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-idempotent")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Decision: \(needle) must appear once after two closes.",
            memoryType: "decision"
        )
        _ = try await endSession(service, sessionID: sessionID)

        let closed = await service.handle(.init(
            command: "session_close",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string("already ended"),
                "project": .string(harvestProject),
            ]
        ))
        #expect(closed.ok == true, "session_close failed: \(closed.error ?? "nil")")
        let payload = try requireObject(closed.payload)
        #expect(payload["already_ended"]?.boolValue == true)
        #expect(payload["active"]?.boolValue == false)

        let recall = try await projectRecall(service, query: needle)
        let matches = recall["results"]?.arrayValue?.filter {
            $0.objectValue?["text"]?.stringValue?.contains(needle) == true
        } ?? []
        #expect(matches.count == 1, "harvest duplicated durable copies: \(matches.count)")
    }
}

@Test
func statsExposeReclaimableBytesAfterWindowElapses() async throws {
    try await withHarvestBroker { service, sessionRoot in
        let sessionID = try await startHarvestSession(service, runID: "harvest-stats")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Decision: stats reclaim token WAXHVST-STATS.",
            memoryType: "decision"
        )
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Working leftover that stays unpromoted without recalls.",
            memoryType: "note"
        )
        _ = try await endSession(service, sessionID: sessionID)

        var manifest = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRoot,
            sessionID: UUID(uuidString: sessionID)!
        )
        manifest.reclaimAfterMs = 1
        try BrokerSessionPersistence.saveManifest(
            manifest,
            to: BrokerSessionPersistence.manifestURL(
                rootURL: sessionRoot,
                sessionID: manifest.sessionID
            )
        )

        let stats = await service.handle(.init(command: "stats"))
        #expect(stats.ok == true, "stats failed: \(stats.error ?? "nil")")
        let sessions = try #require(try requireObject(stats.payload)["sessions"]?.objectValue)
        #expect((sessions["reclaimable_bytes"]?.intValue ?? 0) > 0)
        #expect((sessions["reclaimable"]?.intValue ?? 0) >= 1)
    }
}

@Test
func memoryMaintainDryRunDoesNotUnlinkOrQuarantine() async throws {
    try await withHarvestBroker { service, sessionRoot in
        let sessionID = try await startHarvestSession(service, runID: "maintain-dry")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Decision: dry-run must not unlink WAXHVST-DRY.",
            memoryType: "decision"
        )
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Working leftover stays on disk during dry-run.",
            memoryType: "note"
        )
        _ = try await endSession(service, sessionID: sessionID)
        let storePath = sessionStoreURL(root: sessionRoot, sessionID: sessionID).path
        #expect(FileManager.default.fileExists(atPath: storePath))

        var manifest = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRoot,
            sessionID: UUID(uuidString: sessionID)!
        )
        manifest.reclaimAfterMs = 1
        try BrokerSessionPersistence.saveManifest(
            manifest,
            to: BrokerSessionPersistence.manifestURL(rootURL: sessionRoot, sessionID: manifest.sessionID)
        )

        let dry = await service.handle(.init(command: "memory_maintain"))
        #expect(dry.ok == true, "memory_maintain dry-run failed: \(dry.error ?? "nil")")
        let payload = try requireObject(dry.payload)
        #expect(payload["dry_run"]?.boolValue == true)
        #expect((payload["unlinks"]?.intValue ?? 0) >= 1)
        #expect(FileManager.default.fileExists(atPath: storePath))
    }
}

@Test
func memoryMaintainApplyReclaimsPastWindowAndKeepsNeedle() async throws {
    let needle = "WAXHVAP-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, sessionRoot in
        let sessionID = try await startHarvestSession(service, runID: "maintain-apply")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Decision: \(needle) survives reclaim.",
            memoryType: "decision"
        )
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Working leftover for recently-closed window.",
            memoryType: "note"
        )
        _ = try await endSession(service, sessionID: sessionID)

        var manifest = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRoot,
            sessionID: UUID(uuidString: sessionID)!
        )
        manifest.reclaimAfterMs = 1
        try BrokerSessionPersistence.saveManifest(
            manifest,
            to: BrokerSessionPersistence.manifestURL(rootURL: sessionRoot, sessionID: manifest.sessionID)
        )

        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "memory_maintain apply failed: \(applied.error ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: sessionStoreURL(root: sessionRoot, sessionID: sessionID).path))
        let afterReclaim = try await projectRecall(service, query: needle)
        #expect(firstHitText(afterReclaim).contains(needle))
    }
}

@Test
func zombieActiveLeaseIsEndedAndHarvestedByMaintain() async throws {
    let needle = "WAXHVZB-\(UUID().uuidString.prefix(8))"
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-zombie-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sessionID: String
    let first = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        sessionID = try await startHarvestSession(first, runID: "zombie-run")
        try await rememberSession(
            first,
            sessionID: sessionID,
            content: "Decision: \(needle) must be harvested from a zombie lease.",
            memoryType: "decision"
        )
        try await first.close()
    } catch {
        try? await first.close()
        throw error
    }

    var manifest = try BrokerSessionPersistence.loadManifest(
        rootURL: sessionRootURL,
        sessionID: UUID(uuidString: sessionID)!
    )
    #expect(manifest.status == .active)
    manifest.leaseExpiresAtMs = 1
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: manifest.sessionID)
    )

    let second = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let applied = await second.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "zombie maintain failed: \(applied.error ?? "nil")")
        let harvested = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: UUID(uuidString: sessionID)!
        )
        #expect(harvested.status == .ended)
        #expect(harvested.harvestedAtMs != nil)
        let zombieRecall = try await projectRecall(second, query: needle)
        #expect(firstHitText(zombieRecall).contains(needle))
        try await second.close()
    } catch {
        try? await second.close()
        throw error
    }
}

/// Maintain runs under `commandMutex` only. A remember that rebinds a zombie
/// session while maintain is harvesting it must win: maintain must not mark the
/// now-live session `.ended` underneath it.
@Test(.timeLimit(.minutes(2)))
func maintainDoesNotEndZombieReboundByConcurrentRemember() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-zombie-race-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sessionID: String
    let first = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        sessionID = try await startHarvestSession(first, runID: "zombie-race")
        try await rememberSession(first, sessionID: sessionID, content: "Working note before the race.", memoryType: "note")
        try await first.close()
    } catch {
        try? await first.close()
        throw error
    }
    let uuid = try #require(UUID(uuidString: sessionID))
    var manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: uuid)
    // Freshly expired, not abandoned: startup maintain leaves it for explicit maintain.
    manifest.leaseExpiresAtMs = BrokerClock.nowMs() - 1_000
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: uuid)
    )

    let second = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let (reached, reachedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        await second.setPersistedHarvestHookForTesting { _ in
            reachedSignal.yield()
            for await _ in release { break }
        }
        let maintainDone = RaceFlag()
        let maintain = Task {
            defer { maintainDone.set() }
            return await second.handle(.init(command: "memory_maintain", arguments: ["apply": .bool(true)]))
        }
        for await _ in reached { break }

        // Maintain is parked between harvest and mark-ended. Remember must not
        // wait for it, and its rebind must survive maintain finishing.
        let remember = Task {
            await second.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string("Working note written during maintain."),
                    "session_id": .string(sessionID),
                    "memory_type": .string("note"),
                    "durability": .string("working"),
                    "scope": .string("session"),
                    "project": .string(harvestProject),
                    "repo": .string(harvestProject),
                ]
            ))
        }
        // Maintain stays parked until released, so remember returning here shows it
        // did not queue behind maintain. Wait for the event, not a wall-clock
        // window: a remember that wrongly queues never returns and the time limit
        // fails the test; its cancellation releases maintain so nothing is left parked.
        let written = await withTaskCancellationHandler {
            await remember.value
        } onCancel: {
            releaseSignal.finish()
        }
        let rememberFinishedFirst = !maintainDone.isSet
        releaseSignal.yield()
        releaseSignal.finish()
        let applied = await maintain.value

        #expect(rememberFinishedFirst, "remember waited on memory_maintain")
        #expect(applied.ok, "memory_maintain failed: \(applied.error ?? "nil")")
        #expect(written.ok, "remember failed: \(written.error ?? "nil")")
        let after = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: uuid)
        #expect(after.status == .active, "maintain ended a session a concurrent remember rebound")
        #expect(await second.activeSessions[uuid] != nil)
        try await second.close()
    } catch {
        try? await second.close()
        throw error
    }
}

private final class RaceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Test
func harvestErrorBlocksReclaimUntilForce() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-harvest-error-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sessionID: String
    let first = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        sessionID = try await startHarvestSession(first, runID: "harvest-error")
        try await rememberSession(
            first,
            sessionID: sessionID,
            content: "Decision: this session store will be corrupted before harvest.",
            memoryType: "decision"
        )
        try await first.close()
    } catch {
        try? await first.close()
        throw error
    }

    let waxURL = sessionStoreURL(root: sessionRootURL, sessionID: sessionID)
    try Data("not-a-wax-store".utf8).write(to: waxURL)
    var manifest = try BrokerSessionPersistence.loadManifest(
        rootURL: sessionRootURL,
        sessionID: UUID(uuidString: sessionID)!
    )
    manifest.leaseExpiresAtMs = 1
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: manifest.sessionID)
    )

    let second = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let applied = await second.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "maintain after corrupt harvest failed: \(applied.error ?? "nil")")
        let afterHarvest = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: UUID(uuidString: sessionID)!
        )
        #expect(afterHarvest.status == .ended)
        #expect(afterHarvest.harvestError != nil)
        #expect(FileManager.default.fileExists(atPath: waxURL.path))

        let forced = await second.handle(.init(
            command: "memory_maintain",
            arguments: [
                "apply": .bool(true),
                "force_reclaim": .bool(true),
            ]
        ))
        #expect(forced.ok == true, "force reclaim failed: \(forced.error ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: waxURL.path))
        try await second.close()
    } catch {
        try? await second.close()
        throw error
    }
}

@Test
func oldSessionManifestsDecodeWithoutHarvestFields() throws {
    let json = """
    {
      "sessionID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "agentID": "legacy-agent",
      "runID": "legacy-run",
      "storePath": "/tmp/legacy.wax",
      "eventLogPath": "/tmp/legacy.events.jsonl",
      "status": "ended",
      "createdAtMs": 1,
      "updatedAtMs": 1
    }
    """
    let manifest = try JSONDecoder().decode(BrokerSessionManifest.self, from: Data(json.utf8))
    #expect(manifest.endedAtMs == nil)
    #expect(manifest.harvestedAtMs == nil)
    #expect(manifest.promotedCount == 0)
    #expect(manifest.reclaimAfterMs == nil)
    #expect(manifest.reclaimedAtMs == nil)
    #expect(manifest.harvestError == nil)
}

@Test
func maintainDoesNotQuarantineLockedLibraryRows() async throws {
    let needle = "WAXLOCK-\(UUID().uuidString.prefix(8))"
    let created = Int64(Date().timeIntervalSince1970 * 1000) - 400 * 24 * 60 * 60 * 1000
    try await withHarvestBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: \(needle) is locked library and must not be quarantined."),
                "memory_type": .string("decision"),
                "durability": .string("locked"),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
                "metadata": .object([
                    MemoryMetadataKeys.createdAtMs: .string(String(created)),
                ]),
            ]
        ))
        #expect(write.ok == true, "locked remember failed: \(write.error ?? "nil")")

        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "maintain apply failed: \(applied.error ?? "nil")")
        let lockedRecall = try await projectRecall(service, query: needle)
        #expect(firstHitText(lockedRecall).contains(needle))
    }
}

@Test
func maintainApplySoftDeletesAgedWorkingNotes() async throws {
    let needle = "WAXQUAR-\(UUID().uuidString.prefix(8))"
    let created = Int64(Date().timeIntervalSince1970 * 1000) - 31 * 24 * 60 * 60 * 1000
    try await withHarvestBroker { service, _ in
        // Unscoped broker remember remaps working → durable; maintain scans library rows.
        _ = try await service.longTermMemory.remember(
            "Working scratch \(needle) should be quarantined after 30 days.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.project: harvestProject,
                MemoryMetadataKeys.repo: harvestProject,
                MemoryMetadataKeys.createdAtMs: String(created),
            ]
        )
        try await service.longTermMemory.flush()
        let before = try await projectRecall(service, query: needle)
        #expect(firstHitText(before).contains(needle))

        let dry = await service.handle(.init(command: "memory_maintain"))
        let dryPayload = try requireObject(dry.payload)
        #expect((dryPayload["quarantine_soft_deletes"]?.intValue ?? 0) >= 1)
        let stillThere = try await projectRecall(service, query: needle)
        #expect(firstHitText(stillThere).contains(needle))

        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "quarantine apply failed: \(applied.error ?? "nil")")
        let after = try await projectRecall(service, query: needle)
        #expect(!firstHitText(after).contains(needle))
    }
}

@Test
func maintainApplyReportsPartialQuarantineAndKeepsWhatItDeleted() async throws {
    struct InjectedFailure: Error {}
    let needles = (0..<2).map { _ in "WAXQPART-\(UUID().uuidString.prefix(8))" }
    let created = Int64(Date().timeIntervalSince1970 * 1000) - 31 * 24 * 60 * 60 * 1000
    try await withHarvestBroker { service, _ in
        for needle in needles {
            _ = try await service.longTermMemory.remember(
                "Working scratch \(needle) should be quarantined after 30 days.",
                metadata: [
                    MemoryMetadataKeys.type: MemoryType.note.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                    MemoryMetadataKeys.project: harvestProject,
                    MemoryMetadataKeys.repo: harvestProject,
                    MemoryMetadataKeys.createdAtMs: String(created),
                ]
            )
        }
        try await service.longTermMemory.flush()

        // Let the first soft-delete through, fail every later one.
        let firstDeleted = FirstCallFlag()
        await service.longTermMemory.setDeleteStepHookForTesting { step, _ in
            guard step == .softDelete else { return }
            if firstDeleted.testAndSet() { throw InjectedFailure() }
        }
        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        await service.longTermMemory.setDeleteStepHookForTesting(nil)

        #expect(applied.ok == false)
        #expect((applied.error ?? "").contains("deleted 1 of 2"), "error: \(applied.error ?? "nil")")
        var remaining = 0
        for needle in needles {
            let recall = try await projectRecall(service, query: needle)
            if firstHitText(recall).contains(needle) { remaining += 1 }
        }
        #expect(remaining == 1, "remaining: \(remaining)")
    }
}

/// Returns false on the first call and true afterwards.
private final class FirstCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = set
        set = true
        return was
    }
}

@Test
func coldDurableFramesAreOmittedFromHybridParaphraseRecall() async throws {
    let needle = "WAXCOLD-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: locked library rows must never be auto-deleted by LFU. \(needle)."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
                "metadata": .object([
                    MemoryMetadataKeys.tier: .string(MemoryTier.cold.rawValue),
                ]),
            ]
        ))
        #expect(write.ok == true, "cold remember failed: \(write.error ?? "nil")")

        let paraphrase = try await projectRecall(
            service,
            query: "must never be auto-deleted by LFU",
            mode: "hybrid"
        )
        #expect(!firstHitText(paraphrase).contains(needle))

        let identifier = try await projectRecall(service, query: needle, mode: "text")
        #expect(firstHitText(identifier).contains(needle))
    }
}

@Test
func recallRecordsImpressionsWithoutEngagement() async throws {
    let needle = "WAXIMP-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: \(needle) is used to split impression from engagement."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
            ]
        ))
        #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
        let frameID = try #require(try requireObject(write.payload)["frame_id"]?.intValue)

        _ = try await projectRecall(service, query: needle)
        let afterRecall = await service.longTermMemory.accessStatsSnapshot()[UInt64(frameID)]
        #expect((afterRecall?.impressionCount ?? 0) >= 1)
        #expect(afterRecall?.engagementCount == 0)

        let got = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string("durable:\(frameID)")]
        ))
        #expect(got.ok == true, "memory_get failed: \(got.error ?? "nil")")
        let afterGet = await service.longTermMemory.accessStatsSnapshot()[UInt64(frameID)]
        #expect((afterGet?.engagementCount ?? 0) >= 1)
    }
}

@Test
func applyHarvestPersistsPromotionsWhenHarvestedWithError() {
    var manifest = BrokerSessionManifest(
        sessionID: UUID(),
        agentID: "agent",
        runID: "run",
        project: nil,
        repo: nil,
        storePath: "/tmp/partial.wax",
        eventLogPath: "/tmp/partial.events.jsonl",
        status: .ended,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: 1,
        updatedAtMs: 1
    )
    let report = SessionHarvest.Report(
        harvested: true,
        promotedCount: 3,
        leftoverDocumentCount: 1,
        leftoverLockedCount: 0,
        reclaimAfterMs: 99,
        error: "remember failed",
        alreadyHarvested: false
    )
    VirtualSessionStore.applyHarvest(report, to: &manifest, nowMs: 50)
    #expect(manifest.harvestedAtMs == 50)
    #expect(manifest.promotedCount == 3)
    #expect(manifest.harvestError == "remember failed")
    #expect(manifest.reclaimAfterMs == 99)
    #expect(!report.immediateReclaimEligible)
}

@Test
func harvestReportListsPromotedDurableDecision() async throws {
    let needle = "WAXHVPR-\(UUID().uuidString.prefix(8))"
    let content = "Decision: keep \(needle) as the harvest gold token."
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-promoted-report")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: content,
            memoryType: "decision"
        )

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.harvested)
        #expect(report.promotedCount == report.promoted.count)
        #expect(report.promoted.count == 1)
        let entry = try #require(report.promoted.first)
        #expect(entry.memoryID.hasPrefix("durable:"))
        #expect(entry.type == "decision")
        #expect(entry.preview.contains(needle))
        #expect(entry.preview.count <= content.count)
    }
}

@Test
func harvestReportLabelsWorkingNoteWithoutRecallsAsNoteLowRecall() async throws {
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-note-low-recall")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Working leftover that stays unpromoted without recalls.",
            memoryType: "note"
        )

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.leftoverCount >= 1)
        #expect(report.leftoverCount == report.leftoverDocumentCount)
        #expect(report.leftoverReasons.contains("note_low_recall"))
        #expect(report.promoted.isEmpty)
        #expect(report.promotedCount == 0)
    }
}

@Test
func harvestReportLabelsLockedSessionDocumentAsLocked() async throws {
    let needle = "WAXHVLK-\(UUID().uuidString.prefix(8))"
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-locked-leftover")
        let state = try await liveHarvestState(service, sessionID: sessionID)
        _ = try await state.memory.remember(
            "Decision: locked leftover \(needle) stays in the session store.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
                MemoryMetadataKeys.project: harvestProject,
                MemoryMetadataKeys.repo: harvestProject,
            ]
        )
        try await state.memory.flush()

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.leftoverCount >= 1)
        #expect(report.leftoverLockedCount >= 1)
        #expect(report.leftoverReasons.contains("locked"))
        #expect(report.promoted.isEmpty)
    }
}

@Test
func harvestReportLabelsSecretLikeLeftoverAsSecret() async throws {
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-secret-leftover")
        let state = try await liveHarvestState(service, sessionID: sessionID)
        _ = try await state.memory.remember(
            "Decision: rotate access key AKIAIOSFODNN7EXAMPLE before harvest.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
                MemoryMetadataKeys.project: harvestProject,
                MemoryMetadataKeys.repo: harvestProject,
            ]
        )
        try await state.memory.flush()

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.leftoverCount >= 1)
        #expect(report.leftoverReasons.contains("secret"))
        #expect(report.promoted.isEmpty)
        #expect(report.promotedCount == 0)
    }
}

@Test
func harvestReportLabelsExactDurableDuplicateAsDup() async throws {
    let needle = "WAXHVDP-\(UUID().uuidString.prefix(8))"
    let content = "Decision: keep \(needle) as the canonical harvest token."
    try await withHarvestBroker { service, _ in
        let durable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(content),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
            ]
        ))
        #expect(durable.ok == true, "durable remember failed: \(durable.error ?? "nil")")

        let sessionID = try await startHarvestSession(service, runID: "harvest-dup-leftover")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: content,
            memoryType: "decision"
        )

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.leftoverCount >= 1)
        #expect(report.leftoverReasons.contains("dup"))
        #expect(report.promoted.isEmpty)
        #expect(report.promotedCount == 0)
    }
}

@Test
func findActiveConversationRequiresMatchingAgentProjectAndRepo() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-find-active-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let hostA = UUID()
    let hostB = UUID()
    let otherProject = UUID()
    try saveHarvestManifest(
        harvestManifest(
            sessionID: hostA,
            agentID: "host-a",
            project: "proj",
            repo: "repo-a",
            conversationID: "shared-thread"
        ),
        rootURL: rootURL
    )
    try saveHarvestManifest(
        harvestManifest(
            sessionID: hostB,
            agentID: "host-b",
            runID: "b",
            project: "proj",
            repo: "repo-a",
            conversationID: "shared-thread"
        ),
        rootURL: rootURL
    )
    try saveHarvestManifest(
        harvestManifest(
            sessionID: otherProject,
            agentID: "host-a",
            runID: "c",
            project: "other-proj",
            repo: "repo-a",
            conversationID: "shared-thread"
        ),
        rootURL: rootURL
    )

    let stolen = try BrokerSessionPersistence.findActive(
        conversationID: "shared-thread",
        rootURL: rootURL
    )
    #expect(stolen == nil)

    let namespaced = try BrokerSessionPersistence.findActive(
        conversationID: "shared-thread",
        agentID: "host-a",
        project: "proj",
        repo: "repo-a",
        rootURL: rootURL
    )
    #expect(namespaced?.sessionID == hostA)

    let otherHost = try BrokerSessionPersistence.findActive(
        conversationID: "shared-thread",
        agentID: "host-b",
        project: "proj",
        repo: "repo-a",
        rootURL: rootURL
    )
    #expect(otherHost?.sessionID == hostB)

    let repoMiss = try BrokerSessionPersistence.findActive(
        conversationID: "shared-thread",
        agentID: "host-a",
        project: "proj",
        repo: "repo-b",
        rootURL: rootURL
    )
    #expect(repoMiss == nil)
}

/// Wall time under `swift test --parallel` tracks the whole run, not this test;
/// the limit is only a hang backstop for a close that never drains.
@Test(.timeLimit(.minutes(2)))
func sessionEndHarvestsAdmittedInFlightRemember() async throws {
    let needle = "WAXDRAIN-\(UUID().uuidString.prefix(8))"
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-end-drain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let embedder = ControlledRememberEmbedder()
    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions", isDirectory: true).path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: embedder
    )
    do {
        let sessionID = try await startHarvestSession(service, runID: "drain-end")
        async let remembering = service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: keep \(needle) after in-flight close drain."),
                "memory_type": .string("decision"),
                "durability": .string("working"),
                "scope": .string("session"),
                "session_id": .string(sessionID),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
            ]
        ))
        await embedder.waitUntilEmbeddingStarts()
        async let ending = service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))
        // Release only once teardown is parked behind the in-flight remember, so
        // the drain is exercised on every run instead of racing the release.
        await service.rememberMutex.waitUntilWaiting(atLeast: 1)

        await embedder.release()
        let remembered = await remembering
        let ended = await ending
        #expect(remembered.ok == true, "admitted remember failed: \(remembered.error ?? "nil")")
        #expect(ended.ok == true, "session_end failed: \(ended.error ?? "nil")")
        #expect(ended.payload?.objectValue?["ended"]?.boolValue == true)
        #expect((ended.payload?.objectValue?["promoted_count"]?.intValue ?? 0) >= 1)
        let promoted = ended.payload?.objectValue?["promoted"]?.arrayValue ?? []
        #expect(promoted.contains { item in
            (item.objectValue?["preview"]?.stringValue ?? "").contains(needle)
        })

        let payload = try await projectRecall(service, query: needle)
        #expect(firstHitText(payload).contains(needle))
        try await service.close()
    } catch {
        await embedder.release()
        try? await service.close()
        throw error
    }
}

/// Wall time under `swift test --parallel` tracks the whole run, not this test;
/// the limit is only a hang backstop for a close that never drains.
@Test(.timeLimit(.minutes(2)))
func sessionCloseHarvestsAdmittedInFlightRemember() async throws {
    let needle = "WAXCLOSEDRAIN-\(UUID().uuidString.prefix(8))"
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-close-drain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let embedder = ControlledRememberEmbedder()
    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions", isDirectory: true).path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: embedder
    )
    do {
        let sessionID = try await startHarvestSession(service, runID: "drain-close")
        async let remembering = service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: keep \(needle) after session_close drain."),
                "memory_type": .string("decision"),
                "durability": .string("working"),
                "scope": .string("session"),
                "session_id": .string(sessionID),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
            ]
        ))
        await embedder.waitUntilEmbeddingStarts()
        async let closing = service.handle(.init(
            command: "session_close",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string("drain close"),
                "project": .string(harvestProject),
            ]
        ))
        // Release only once teardown is parked behind the in-flight remember, so
        // the drain is exercised on every run instead of racing the release.
        await service.rememberMutex.waitUntilWaiting(atLeast: 1)

        await embedder.release()
        let remembered = await remembering
        let closed = await closing
        #expect(remembered.ok == true, "admitted remember failed: \(remembered.error ?? "nil")")
        #expect(closed.ok == true, "session_close failed: \(closed.error ?? "nil")")
        #expect(closed.payload?.objectValue?["ended"]?.boolValue == true)
        #expect((closed.payload?.objectValue?["promoted_count"]?.intValue ?? 0) >= 1)

        let payload = try await projectRecall(service, query: needle)
        #expect(firstHitText(payload).contains(needle))
        try await service.close()
    } catch {
        await embedder.release()
        try? await service.close()
        throw error
    }
}

private func harvestManifest(
    sessionID: UUID,
    agentID: String,
    runID: String = "a",
    project: String?,
    repo: String?,
    conversationID: String
) -> BrokerSessionManifest {
    BrokerSessionManifest(
        sessionID: sessionID,
        agentID: agentID,
        runID: runID,
        project: project,
        repo: repo,
        storePath: "/tmp/\(sessionID.uuidString).wax",
        eventLogPath: "/tmp/\(sessionID.uuidString).events.jsonl",
        status: .active,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: 1,
        updatedAtMs: 1,
        conversationID: conversationID
    )
}

private func saveHarvestManifest(_ manifest: BrokerSessionManifest, rootURL: URL) throws {
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: manifest.sessionID)
    )
}

private actor ControlledRememberEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Test",
        model: "ControlledRemember",
        dimensions: 2,
        normalized: true
    )
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return [1.0, 0.0]
    }

    func waitUntilEmbeddingStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private func rememberDurable(
    _ service: AgentBrokerService,
    content: String,
    project: String
) async throws {
    let write = await service.handle(.init(
        command: "remember",
        arguments: [
            "content": .string(content),
            "memory_type": .string("decision"),
            "project": .string(project),
            "repo": .string(project),
        ]
    ))
    #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
}

// Project-scoped recall hides another project's durable memory, so a match
// there must not count as a duplicate: the session store is reclaimed after harvest.
@Test
func harvestPromotesTextThatOnlyDuplicatesAnotherProjectsMemory() async throws {
    let needle = "WAXHVXP-\(UUID().uuidString.prefix(8))"
    let text = "Decision: keep \(needle) as the cross-project harvest token."
    try await withHarvestBroker { service, _ in
        try await rememberDurable(service, content: text, project: "harvest-elsewhere")
        let sessionID = try await startHarvestSession(service, runID: "harvest-cross-project")
        try await rememberSession(service, sessionID: sessionID, content: text, memoryType: "decision")

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.promotedCount == 1)
        #expect(!report.leftoverReasons.contains("dup"), "reasons: \(report.leftoverReasons)")

        let payload = try await projectRecall(service, query: needle)
        #expect(firstHitText(payload).contains(needle), "project recall missed promoted memory")
    }
}

@Test
func harvestStillDedupesTextAlreadyDurableInTheSameProject() async throws {
    let needle = "WAXHVSP-\(UUID().uuidString.prefix(8))"
    let text = "Decision: keep \(needle) as the same-project harvest token."
    try await withHarvestBroker { service, _ in
        try await rememberDurable(service, content: text, project: harvestProject)
        let sessionID = try await startHarvestSession(service, runID: "harvest-same-project")
        try await rememberSession(service, sessionID: sessionID, content: text, memoryType: "decision")

        let report = try await harvestLiveSession(service, sessionID: sessionID)
        #expect(report.promotedCount == 0)
        #expect(report.leftoverReasons == ["dup"])
    }
}

@Test
func memoryPromoteWritesTextThatOnlyDuplicatesAnotherProjectsMemory() async throws {
    let needle = "WAXPRXP-\(UUID().uuidString.prefix(8))"
    let text = "Decision: keep \(needle) as the cross-project promote token."
    try await withHarvestBroker { service, _ in
        try await rememberDurable(service, content: text, project: "harvest-elsewhere")
        let sessionID = try await startHarvestSession(service, runID: "promote-cross-project")
        let promoted = await service.handle(.init(
            command: "memory_promote",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string(text),
                "approve": .bool(true),
                "memory_type": .string("decision"),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
            ]
        ))
        #expect(promoted.ok == true, "memory_promote failed: \(promoted.error ?? "nil")")
        #expect(promoted.payload?.objectValue?["written"]?.boolValue == true)
    }
}

@Test
func harvestReclaimDeadlineSaturatesForHugeRecentlyClosedWindow() async throws {
    try await withHarvestBroker { service, _ in
        let sessionID = try await startHarvestSession(service, runID: "harvest-huge-window")
        try await rememberSession(
            service,
            sessionID: sessionID,
            content: "Working note that stays behind as a low-recall leftover.",
            memoryType: "note"
        )
        let state = try await liveHarvestState(service, sessionID: sessionID)
        let retention = MemoryRetentionSettings.fromEnvironment([
            "WAX_SESSION_RECENTLY_CLOSED_SECS": String(Int64.max / 1000),
        ])
        let report = await SessionHarvest.run(
            sessionMemory: state.memory,
            longTermMemory: service.longTermMemory,
            sessionID: state.id,
            manifest: state.manifest,
            events: [],
            scope: MemoryScopeContext(repoName: harvestProject, projectName: harvestProject),
            retention: retention,
            nowMs: BrokerClock.nowMs()
        )
        #expect(report.leftoverDocumentCount == 1)
        #expect(report.reclaimAfterMs == Int64.max)
    }
}
