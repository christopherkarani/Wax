import Foundation
import Testing
@testable import Wax

private func withMaintainBroker<T>(
    retentionSettings: MemoryRetentionSettings = .default,
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-maintain-settings-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableTextSearch = true
    config.liveSetRewriteSchedule = .disabled

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: config,
        retentionSettings: retentionSettings
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

/// A working library row stamped two hours old: inside the 30-day default
/// window, outside a one-hour `WAX_WORKING_QUARANTINE_SECS`. Seeded directly
/// because unscoped broker remember remaps working → durable.
private func rememberTwoHourOldWorkingNote(_ service: AgentBrokerService) async throws {
    let createdAtMs = BrokerClock.nowMs() - 2 * 60 * 60 * 1000
    _ = try await service.longTermMemory.remember(
        "maintain settings working note \(UUID().uuidString.prefix(8))",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
            MemoryMetadataKeys.project: "wax-maintain-settings",
            MemoryMetadataKeys.createdAtMs: String(createdAtMs),
        ]
    )
    try await service.longTermMemory.flush()
}

private func dryRunQuarantineCount(_ service: AgentBrokerService) async throws -> Int64 {
    let response = await service.handle(.init(command: "memory_maintain", arguments: [:]))
    #expect(response.ok, "memory_maintain failed: \(response.error ?? "nil")")
    let payload = try #require(response.payload?.objectValue)
    #expect(try #require(payload["dry_run"]?.boolValue))
    return try #require(payload["quarantine_soft_deletes"]?.intValue)
}

@Test
func maintainUsesDefaultWorkingQuarantineWindow() async throws {
    try await withMaintainBroker { service, _ in
        try await rememberTwoHourOldWorkingNote(service)
        #expect(try await dryRunQuarantineCount(service) == 0)
    }
}

@Test
func maintainHonorsCustomWorkingQuarantineSetting() async throws {
    let settings = MemoryRetentionSettings.fromEnvironment(["WAX_WORKING_QUARANTINE_SECS": "3600"])
    #expect(settings.workingQuarantineMs == 3_600_000)
    try await withMaintainBroker(retentionSettings: settings) { service, _ in
        try await rememberTwoHourOldWorkingNote(service)
        #expect(try await dryRunQuarantineCount(service) == 1)
    }
}

@Test
func statsSurfacesSessionManifestListingFailure() async throws {
    try await withMaintainBroker { service, sessionRootURL in
        // A UUID-named manifest that does not decode makes the listing throw.
        let corrupt = sessionRootURL.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: corrupt)

        let response = await service.handle(.init(command: "stats"))
        #expect(response.ok, "stats failed: \(response.error ?? "nil")")
        let sessions = try #require(response.payload?.objectValue?["sessions"]?.objectValue)
        let listError = try #require(sessions["list_error"]?.stringValue)
        #expect(!listError.isEmpty)

        // Not cached: once the bad manifest is gone the next stats call recovers.
        try FileManager.default.removeItem(at: corrupt)
        let recovered = await service.handle(.init(command: "stats"))
        let recoveredSessions = try #require(recovered.payload?.objectValue?["sessions"]?.objectValue)
        #expect(recoveredSessions["list_error"] == nil)
    }
}

@Test
func clientResponseTimeoutOutlastsBrokerEmbedderWait() {
    #expect(BrokerLimits.defaultClientResponseTimeoutSeconds > BrokerLimits.embedderReadyWaitSeconds)
    if ProcessInfo.processInfo.environment["WAX_BROKER_RESPONSE_TIMEOUT_SECS"] == nil {
        #expect(AgentBrokerClient.responseTimeoutSeconds == BrokerLimits.defaultClientResponseTimeoutSeconds)
    }
}

@Test
func sessionEndHarvestUsesBrokerRetentionSettings() async throws {
    var settings = MemoryRetentionSettings.default
    settings.recentlyClosedMs = 7_200_000
    try await withMaintainBroker(retentionSettings: settings) { service, _ in
        let project = "maintain-settings-harvest"
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("settings-agent"),
                "run_id": .string("settings-harvest"),
                "project": .string(project),
                "repo": .string(project),
            ]
        ))
        #expect(started.ok, "session_start failed: \(started.error ?? "nil")")
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        // A working note is a harvest leftover, so reclaim waits recentlyClosedMs.
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working note that stays in the session store."),
                "session_id": .string(sessionID),
                "memory_type": .string("note"),
                "durability": .string("working"),
                "scope": .string("session"),
                "project": .string(project),
                "repo": .string(project),
            ]
        ))
        #expect(write.ok, "remember failed: \(write.error ?? "nil")")

        let before = BrokerClock.nowMs()
        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(ended.ok, "session_end failed: \(ended.error ?? "nil")")
        let reclaimAfterMs = try #require(ended.payload?.objectValue?["reclaim_after_ms"]?.intValue)
        #expect(reclaimAfterMs >= before + settings.recentlyClosedMs)
        #expect(reclaimAfterMs < before + settings.recentlyClosedMs + 600_000)
    }
}

@Test(arguments: ["abc", "1h", ""])
func workingQuarantineNonNumericWarnsAndUsesDefault(_ raw: String) {
    var warnings: [String] = []
    let settings = MemoryRetentionSettings.fromEnvironment(
        ["WAX_WORKING_QUARANTINE_SECS": raw],
        warn: { warnings.append($0) }
    )
    #expect(settings.workingQuarantineMs == MemoryRetentionSettings.default.workingQuarantineMs)
    #expect(warnings.count == 1)
}

@Test(arguments: ["0", "-5"])
func workingQuarantineNonPositiveFallsBackToDefault(_ raw: String) {
    var warnings: [String] = []
    let settings = MemoryRetentionSettings.fromEnvironment(
        ["WAX_WORKING_QUARANTINE_SECS": raw],
        warn: { warnings.append($0) }
    )
    #expect(settings.workingQuarantineMs == MemoryRetentionSettings.default.workingQuarantineMs)
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("WAX_WORKING_QUARANTINE_SECS") ?? false)
}

@Test
func workingQuarantineBelowMinimumIsClampedToOneHour() {
    var warnings: [String] = []
    let settings = MemoryRetentionSettings.fromEnvironment(
        ["WAX_WORKING_QUARANTINE_SECS": "60"],
        warn: { warnings.append($0) }
    )
    #expect(settings.workingQuarantineMs == MemoryRetentionSettings.minimumWorkingQuarantineMs)
    #expect(MemoryRetentionSettings.minimumWorkingQuarantineMs == 3_600_000)
    #expect(warnings.count == 1)

    warnings.removeAll()
    let atMinimum = MemoryRetentionSettings.fromEnvironment(
        ["WAX_WORKING_QUARANTINE_SECS": "3600"],
        warn: { warnings.append($0) }
    )
    #expect(atMinimum.workingQuarantineMs == 3_600_000)
    #expect(warnings.isEmpty)
}
