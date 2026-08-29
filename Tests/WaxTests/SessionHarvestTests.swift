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
func emptyPromotableSessionUnlinksImmediately() async throws {
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
        #expect(ended["reclaimed"]?.boolValue == true)
        #expect(!FileManager.default.fileExists(atPath: sessionStoreURL(root: sessionRoot, sessionID: sessionID).path))

        let manifest = try BrokerSessionPersistence.loadManifest(
            rootURL: sessionRoot,
            sessionID: UUID(uuidString: sessionID)!
        )
        #expect(manifest.reclaimedAtMs != nil)
        #expect(manifest.status == .ended)

        let payload = try await projectRecall(service, query: needle)
        #expect(firstHitText(payload).contains(needle))
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
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working scratch \(needle) should be quarantined after 30 days."),
                "memory_type": .string("note"),
                "durability": .string("working"),
                "project": .string(harvestProject),
                "repo": .string(harvestProject),
                "metadata": .object([
                    MemoryMetadataKeys.createdAtMs: .string(String(created)),
                ]),
            ]
        ))
        #expect(write.ok == true, "working remember failed: \(write.error ?? "nil")")
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
