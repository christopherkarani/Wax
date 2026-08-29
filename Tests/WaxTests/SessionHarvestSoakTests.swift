import Foundation
import Testing
@testable import Wax

@Test
func sessionHarvestSoakPromotesNeedleAndReclaimsStore() async throws {
    let distractorCount = max(
        50,
        ProcessInfo.processInfo.environment["WAX_HARVEST_SOAK_COUNT"].flatMap(Int.init) ?? 50
    )
    let needle = "WAXSOAK-\(UUID().uuidString.prefix(8))"
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-harvest-soak-\(UUID().uuidString)", isDirectory: true)
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
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("soak-agent"),
                "run_id": .string("soak-run"),
                "project": .string("soak-qa"),
                "repo": .string("soak-qa"),
            ]
        ))
        #expect(started.ok == true, "session_start failed: \(started.error ?? "nil")")
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)

        let needleWrite = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: \(needle) is the soak harvest gold token."),
                "session_id": .string(sessionID),
                "memory_type": .string("decision"),
                "durability": .string("working"),
                "project": .string("soak-qa"),
                "repo": .string("soak-qa"),
            ]
        ))
        #expect(needleWrite.ok == true, "needle remember failed: \(needleWrite.error ?? "nil")")

        for index in 0..<distractorCount {
            let write = await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string("Soak distractor \(index) has no gold token and should stay unpromoted."),
                    "session_id": .string(sessionID),
                    "memory_type": .string("note"),
                    "durability": .string("working"),
                    "project": .string("soak-qa"),
                    "repo": .string("soak-qa"),
                ]
            ))
            #expect(write.ok == true, "distractor \(index) remember failed: \(write.error ?? "nil")")
        }

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(ended.ok == true, "session_end failed: \(ended.error ?? "nil")")
        #expect(ended.payload?.objectValue?["harvested"]?.boolValue == true)

        let recall = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(needle),
                "mode": .string("text"),
                "scope": .string("project"),
                "project": .string("soak-qa"),
                "repo": .string("soak-qa"),
                "limit": .int(8),
            ]
        ))
        #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
        let top = recall.payload?.objectValue?["results"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(top.contains(needle), "soak durable recall missed needle; top=\(top)")

        let uuid = try #require(UUID(uuidString: sessionID))
        var manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: uuid)
        manifest.reclaimAfterMs = 1
        try BrokerSessionPersistence.saveManifest(
            manifest,
            to: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: uuid)
        )
        let applied = await service.handle(.init(
            command: "memory_maintain",
            arguments: ["apply": .bool(true)]
        ))
        #expect(applied.ok == true, "soak reclaim failed: \(applied.error ?? "nil")")
        #expect(
            !FileManager.default.fileExists(
                atPath: sessionRootURL.appendingPathComponent("\(sessionID).wax").path
            )
        )

        let after = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(needle),
                "mode": .string("text"),
                "scope": .string("project"),
                "project": .string("soak-qa"),
                "repo": .string("soak-qa"),
                "limit": .int(8),
            ]
        ))
        let afterTop = after.payload?.objectValue?["results"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(afterTop.contains(needle))
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}
