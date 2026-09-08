#if MCPServer
import Foundation
import Testing
@testable import Wax

@Suite("WaxMCPHandoffScopeTests")
struct WaxMCPHandoffScopeTests {
    @Test(arguments: ["handoff", "session_close"], [nil, "   ", "override-project"] as [String?])
    func handoffProjectSurvivesBrokerRebind(command: String, explicitProject: String?) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-handoff-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeBroker() async throws -> AgentBrokerService {
            try await AgentBrokerService(
                storePath: root.appendingPathComponent("memory.wax").path,
                sessionRootPath: root.appendingPathComponent("sessions").path,
                noEmbedder: true,
                embedderChoice: "auto",
                requireVector: false
            )
        }

        let original = try await makeBroker()
        let opened = await original.handle(.init(
            command: "session_open",
            arguments: [
                "project": .string("session-project"),
                "agent_id": .string("handoff-agent"),
                "run_id": .string("original-run"),
            ]
        ))
        // Release the original broker before assertions so failures do not leave it open.
        try await original.close()
        let sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)

        let broker = try await makeBroker()
        do {
            var arguments: [String: AgentBrokerValue] = [
                "session_id": .string(sessionID),
                "content": .string("Continue the memory retrieval investigation."),
                "pending_tasks": .array([.string("Verify the next retrieval result")]),
            ]
            if let explicitProject { arguments["project"] = .string(explicitProject) }
            let written = await broker.handle(.init(command: command, arguments: arguments))
            #expect(written.ok, "\(command) failed: \(written.error ?? "nil")")

            let expectedProject = explicitProject == "override-project" ? "override-project" : "session-project"
            let latest = await broker.handle(.init(
                command: "handoff_latest",
                arguments: ["project": .string(expectedProject)]
            ))
            #expect(latest.ok)
            #expect(latest.payload?.objectValue?["found"]?.boolValue == true)
            #expect(latest.payload?.objectValue?["project"]?.stringValue == expectedProject)
            #expect(latest.payload?.objectValue?["content"]?.stringValue == "Continue the memory retrieval investigation.")

            let next = await broker.handle(.init(
                command: "session_open",
                arguments: [
                    "project": .string(expectedProject),
                    "agent_id": .string("next-agent"),
                    "run_id": .string("next-run"),
                ]
            ))
            #expect(next.ok)
            #expect(next.payload?.objectValue?["handoff"]?.objectValue?["found"]?.boolValue == true)
            try await broker.close()
        } catch {
            try? await broker.close()
            throw error
        }
    }
}
#endif
