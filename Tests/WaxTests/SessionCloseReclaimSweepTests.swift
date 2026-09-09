import Foundation
import Testing
@testable import Wax

@Suite("SessionCloseReclaimSweepTests")
struct SessionCloseReclaimSweepTests {
    @Test
    func sessionCloseUnlinksReclaimableEndedStoreAndKeepsRecentlyClosed() async throws {
        try await withStartupGCRoots { storeURL, sessionRootURL in
            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { service in
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let reclaimableID = UUID()
                let recentID = UUID()
                let liveID = UUID()
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
                    reclaimAfterMs: nowMs + MemoryRetentionSettings.default.recentlyClosedMs
                )

                let started = await service.handle(.init(command: "session_start", arguments: [
                    "session_id": .string(liveID.uuidString),
                    "project": .string("startup-gc"),
                ]))
                #expect(started.ok)

                let closed = await service.handle(.init(command: "session_close", arguments: [
                    "session_id": .string(liveID.uuidString),
                    "content": .string("close sweep"),
                    "project": .string("startup-gc"),
                ]))
                #expect(closed.ok, "session_close failed: \(closed.error ?? "nil")")

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
            }
        }
    }

    @Test
    func sessionCloseDoesNotQuarantineLongTermWorkingMemory() async throws {
        try await withStartupGCRoots { storeURL, sessionRootURL in
            try await withStartupBroker(storePath: storeURL.path, sessionRootPath: sessionRootURL.path) { service in
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let canary = "CLOSE-SWEEP-CANARY-\(UUID().uuidString.prefix(8))"
                let createdAtMs = nowMs - MemoryRetentionSettings.default.workingQuarantineMs - 1_000
                let remembered = await service.handle(.init(command: "remember", arguments: [
                    "content": .string(canary),
                    "memory_type": .string(MemoryType.note.rawValue),
                    "durability": .string(MemoryDurability.working.rawValue),
                    "metadata": .object([
                        MemoryMetadataKeys.createdAtMs: .string(String(createdAtMs)),
                    ]),
                ]))
                #expect(remembered.ok, "remember failed: \(remembered.error ?? "nil")")
                let rememberPayload = try #require(remembered.payload?.objectValue)
                let memoryID = try #require(rememberPayload["memory_id"]?.stringValue)

                let liveID = UUID()
                let started = await service.handle(.init(command: "session_start", arguments: [
                    "session_id": .string(liveID.uuidString),
                    "project": .string("startup-gc"),
                ]))
                #expect(started.ok)

                let closed = await service.handle(.init(command: "session_close", arguments: [
                    "session_id": .string(liveID.uuidString),
                    "content": .string("close must not GC library"),
                    "project": .string("startup-gc"),
                ]))
                #expect(closed.ok, "session_close failed: \(closed.error ?? "nil")")

                let fetched = await service.handle(.init(command: "memory_get", arguments: [
                    "memory_id": .string(memoryID),
                ]))
                #expect(fetched.ok, "memory_get failed: \(fetched.error ?? "nil")")
                let text = fetched.payload?.objectValue?["text"]?.stringValue ?? ""
                #expect(text.contains(canary))
            }
        }
    }
}
