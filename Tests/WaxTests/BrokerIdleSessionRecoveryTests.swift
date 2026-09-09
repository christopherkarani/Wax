import Foundation
import Testing
@testable import Wax

@Suite("BrokerIdleSessionRecoveryTests")
struct BrokerIdleSessionRecoveryTests {
    @Test
    func expiredLeaseSurvivesRestartUntilExplicitSessionClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-idle-recovery-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeBroker() async throws -> AgentBrokerService {
            try await AgentBrokerService(
                storePath: root.appendingPathComponent("memory.wax").path,
                sessionRootPath: sessions.path,
                noEmbedder: true,
                embedderChoice: "auto",
                requireVector: false
            )
        }

        let first = try await makeBroker()
        let sessionID: String
        do {
            let opened = await first.handle(.init(command: "session_open", arguments: [
                "agent_id": .string("idle-recovery-agent"),
                "run_id": .string("idle-recovery-run"),
                "project": .string("idle-recovery-project"),
            ]))
            sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
            let remembered = await first.handle(.init(command: "remember", arguments: [
                "session_id": .string(sessionID),
                "memory_type": .string("task_state"),
                "content": .string("IDLE_RECOVERY_ANCHOR: continue verifying the memory retrieval path."),
            ]))
            #expect(remembered.ok, "Initial write failed: \(remembered.error ?? "nil")")
            try await first.close()
        } catch {
            try? await first.close()
            throw error
        }

        let uuid = try #require(UUID(uuidString: sessionID))
        var manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessions, sessionID: uuid)
        #expect(manifest.status == .active)
        // Simulate a fresh idle expiry (seconds ago). Epoch sentinels look
        // abandoned (≥ recently-closed window) and init would harvest them.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        manifest.leaseExpiresAtMs = nowMs - 1_000
        try BrokerSessionPersistence.saveManifest(
            manifest,
            to: BrokerSessionPersistence.manifestURL(rootURL: sessions, sessionID: uuid)
        )

        let second = try await makeBroker()
        do {
            let restarted = try BrokerSessionPersistence.loadManifest(rootURL: sessions, sessionID: uuid)
            #expect(restarted.status == .active)
            #expect(restarted.harvestedAtMs == nil)
            let recalled = await second.handle(.init(command: "recall", arguments: [
                "session_id": .string(sessionID),
                "query": .string("IDLE_RECOVERY_ANCHOR"),
                "mode": .string("text"),
            ]))
            #expect(recalled.ok, "Recall after idle failed: \(recalled.error ?? "nil")")
            let rows = recalled.payload?.objectValue?["results"]?.arrayValue ?? []
            #expect(rows.contains { row in
                row.objectValue?["text"]?.stringValue?.contains("IDLE_RECOVERY_ANCHOR") == true
            })

            let write = AgentBrokerRequest(command: "remember", arguments: [
                "session_id": .string(sessionID),
                "memory_type": .string("task_state"),
                "content": .string("Continue using the same session after broker recovery."),
            ])
            let remembered = await second.handle(write)
            #expect(remembered.ok, "Write after idle failed: \(remembered.error ?? "nil")")
            #expect(remembered.payload?.objectValue?["session_id"]?.stringValue == sessionID)

            let closed = await second.handle(.init(command: "session_close", arguments: [
                "session_id": .string(sessionID),
                "content": .string("Idle recovery verification completed."),
            ]))
            #expect(closed.ok)
            let rejected = await second.handle(write)
            #expect(!rejected.ok)
            #expect(rejected.payload?.objectValue?["code"]?.stringValue == "session_ended")
            try await second.close()
        } catch {
            try? await second.close()
            throw error
        }
    }
}
