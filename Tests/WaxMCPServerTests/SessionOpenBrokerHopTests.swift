#if MCPServer
import Foundation
import Testing
@testable import Wax

@Suite
struct SessionOpenBrokerHopTests {
    private func makeBroker(root: URL) async throws -> AgentBrokerService {
        try await AgentBrokerService(
            storePath: root.appendingPathComponent("memory.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )
    }

    @Test func openResumesPersistedActiveUUIDAfterBrokerRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-open-broker-hop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await makeBroker(root: root)
        let sessionID: String
        do {
            let opened = await first.handle(.init(
                command: "session_open", arguments: ["project": .string("broker-hop")]
            ))
            sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
            let remembered = await first.handle(.init(command: "remember", arguments: [
                "session_id": .string(sessionID),
                "memory_type": .string("task_state"),
                "content": .string("BROKER-HOP-CONTINUITY continue the session recovery investigation"),
            ]))
            #expect(remembered.ok, "\(remembered.error ?? "remember failed")")
            try await first.close()
        } catch {
            try? await first.close()
            throw error
        }

        let second = try await makeBroker(root: root)
        do {
            let reopened = await second.handle(.init(command: "session_open", arguments: [
                "session_id": .string(sessionID),
                "recall_query": .string("BROKER-HOP-CONTINUITY"),
            ]))
            #expect(reopened.ok, "\(reopened.error ?? "session_open failed")")
            let payload = try #require(reopened.payload?.objectValue)
            #expect(payload["session_id"]?.stringValue == sessionID)
            let results = payload["recall"]?.objectValue?["results"]?.arrayValue ?? []
            #expect(results.contains {
                let hit = $0.objectValue
                return (hit?["text"]?.stringValue ?? hit?["preview"]?.stringValue ?? "")
                    .contains("BROKER-HOP-CONTINUITY")
            })
            try await second.close()
        } catch {
            try? await second.close()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func openReplacesUnknownOrEndedHint(ended: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-open-stale-hint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = try await makeBroker(root: root)
        do {
            var staleID = UUID().uuidString
            if ended {
                let opened = await broker.handle(.init(command: "session_open", arguments: [:]))
                staleID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
                let closed = await broker.handle(.init(command: "session_close", arguments: [
                    "session_id": .string(staleID),
                    "content": .string("Finished the prior task."),
                ]))
                #expect(closed.ok)
            }
            let reopened = await broker.handle(.init(command: "session_open", arguments: [
                "session_id": .string(staleID),
            ]))
            #expect(reopened.ok)
            let newID = try #require(reopened.payload?.objectValue?["session_id"]?.stringValue)
            #expect(newID != staleID)
            try await broker.close()
        } catch {
            try? await broker.close()
            throw error
        }
    }
}
#endif
