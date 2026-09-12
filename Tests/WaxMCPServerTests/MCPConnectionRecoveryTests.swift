#if MCPServer
import Foundation
import MCP
import Testing
@testable import wax_mcp
@testable import Wax

@Suite(.serialized)
struct MCPConnectionRecoveryTests {
    @Test func metadataFilterSchemaSupportsExactWrapperWithoutMixedKeys() throws {
        let metadata = try #require(ToolSchemas.searchFilters.objectValue?["properties"]?.objectValue?["metadata"])
        let branches = try #require(metadata.objectValue?["oneOf"]?.arrayValue)
        let wrapper = try #require(branches.first {
            $0.objectValue?["properties"]?.objectValue?["exact"] != nil
        }?.objectValue)
        #expect(wrapper["required"]?.arrayValue == [.string("exact")])
        #expect(wrapper["additionalProperties"] == .bool(false))
        let exact = try #require(wrapper["properties"]?.objectValue?["exact"]?.objectValue)
        #expect(exact["type"] == .string("object"))
        #expect(exact["additionalProperties"]?.objectValue?["oneOf"]?.arrayValue != nil)
        let flat = try #require(branches.first {
            $0.objectValue?["properties"]?.objectValue?["exact"] == nil
        }?.objectValue)
        #expect(flat["additionalProperties"] == exact["additionalProperties"])
        #expect(flat["not"]?.objectValue?["required"]?.arrayValue == [.string("exact")])
    }

    @Test func integerMetadataMatchesExactlyOneSchemaBranch() throws {
        let metadata = try #require(ToolSchemas.waxRemember.objectValue?["properties"]?.objectValue?["metadata"])
        let schema = try #require(metadata.objectValue?["additionalProperties"]?.objectValue)
        if let branches = schema["oneOf"]?.arrayValue {
            let numericMatches = branches.filter {
                let type = $0.objectValue?["type"]?.stringValue
                return type == "integer" || type == "number"
            }
            #expect(numericMatches.count == 1)
        } else {
            #expect(schema["anyOf"]?.arrayValue != nil)
        }
    }

    private func withBroker(_ body: (AgentBrokerService) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wax-connection-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = try await AgentBrokerService(
            storePath: root.appendingPathComponent("memory.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )
        do {
            try await body(broker)
            try await broker.close()
        } catch {
            try? await broker.close()
            throw error
        }
    }

    private func json(_ result: CallTool.Result) throws -> [String: Any] {
        let text = result.content.compactMap { block -> String? in
            if case .text(let text, _, _) = block { return text }
            return nil
        }.joined(separator: "\n")
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func open(_ broker: AgentBrokerService, hint: MCPClientSessionHint) async throws -> String {
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "session_open", arguments: ["project": .string("connection-recovery")]),
            broker: broker,
            sessionHint: hint
        )
        return try #require(json(result)["session_id"] as? String)
    }

    @Test func explicitBrokerSessionOverridesConnectionHint() async throws {
        try await withBroker { broker in
            let firstHint = MCPClientSessionHint()
            let firstID = try await open(broker, hint: firstHint)
            let secondID = try await open(broker, hint: MCPClientSessionHint())
            #expect(firstID != secondID)
            let result = await WaxMCPTools.handleCall(
                params: .init(name: "remember", arguments: [
                    "session_id": .string(secondID),
                    "memory_type": .string("task_state"),
                    "content": .string("Continue the connection recovery regression task."),
                ]),
                broker: broker,
                sessionHint: firstHint
            )
            #expect(result.isError != true)
            #expect(firstHint.current() == firstID)
        }
    }

    @Test func compactContextUsesBoundSessionAmongMultipleActiveSessions() async throws {
        try await withBroker { broker in
            let hint = MCPClientSessionHint()
            _ = try await open(broker, hint: hint)
            _ = try await open(broker, hint: MCPClientSessionHint())
            let result = await WaxMCPTools.handleCall(
                params: .init(name: "compact_context", arguments: [
                    "query": .string("connection recovery"), "mode": .string("text"),
                ]),
                broker: broker,
                sessionHint: hint
            )
            #expect(result.isError != true)
        }
    }

    @Test func sessionResumeUsesConnectionDefaultUnlessExplicitlySelected() async throws {
        try await withBroker { broker in
            let hint = MCPClientSessionHint()
            let firstID = try await open(broker, hint: hint)
            let other = await WaxMCPTools.handleCall(
                params: .init(name: "session_open", arguments: [
                    "project": .string("connection-recovery"),
                    "agent_id": .string("other-agent"), "run_id": .string("other-run"),
                ]),
                broker: broker, sessionHint: MCPClientSessionHint()
            )
            let secondID = try #require(json(other)["session_id"] as? String)
            #expect(firstID != secondID)

            let resumed = await WaxMCPTools.handleCall(
                params: .init(name: "session_resume", arguments: [:]),
                broker: broker, sessionHint: hint
            )
            #expect(resumed.isError != true)
            #expect(try json(resumed)["session_id"] as? String == firstID)
            #expect(hint.current() == firstID)

            let selected = await WaxMCPTools.handleCall(
                params: .init(name: "session_resume", arguments: [
                    "agent_id": .string("other-agent"), "run_id": .string("other-run"),
                ]),
                broker: broker, sessionHint: hint
            )
            #expect(selected.isError != true)
            #expect(try json(selected)["session_id"] as? String == secondID)
            #expect(hint.current() == secondID)
        }
    }

    @Test func openingAnotherProjectPreservesPriorSessionIdentity() async throws {
        try await withBroker { broker in
            let hint = MCPClientSessionHint()
            let firstID = try await open(broker, hint: hint)
            let next = await WaxMCPTools.handleCall(
                params: .init(name: "session_open", arguments: ["project": .string("another-project")]),
                broker: broker, sessionHint: hint
            )
            #expect(next.isError != true)
            let secondID = try #require(json(next)["session_id"] as? String)
            #expect(secondID != firstID)
            let written = await WaxMCPTools.handleCall(
                params: .init(name: "remember", arguments: [
                    "session_id": .string(firstID), "memory_type": .string("fact"),
                    "content": .string("The original project retains its own session identity."),
                ]), broker: broker, sessionHint: hint
            )
            #expect(written.isError != true)
            #expect(try json(written)["project"] as? String == "connection-recovery")
            #expect(hint.current() == secondID)
        }
    }

    @Test func memoryAppendAliasInheritsConnectionSession() async throws {
        try await withBroker { broker in
            let hint = MCPClientSessionHint()
            let sessionID = try await open(broker, hint: hint)
            _ = try await open(broker, hint: MCPClientSessionHint())
            let result = await WaxMCPTools.handleCall(
                params: .init(name: "memory_append", arguments: [
                    "memory_type": .string("task_state"),
                    "content": .string("Continue the alias session inheritance regression task."),
                ]),
                broker: broker,
                sessionHint: hint
            )
            #expect(result.isError != true)
            #expect(try json(result)["session_id"] as? String == sessionID)
        }
    }

    @Test func inactiveSessionRecoveryFieldsAreVisibleToTextOnlyHosts() async throws {
        try await withBroker { broker in
            let hint = MCPClientSessionHint()
            _ = try await open(broker, hint: hint)
            let result = await WaxMCPTools.handleCall(
                params: .init(name: "remember", arguments: [
                    "session_id": .string(UUID().uuidString),
                    "memory_type": .string("task_state"),
                    "content": .string("This unknown session must not accept a write."),
                ]),
                broker: broker,
                sessionHint: hint
            )
            #expect(result.isError == true)
            let payload = try json(result)
            #expect(payload["code"] as? String != nil)
            #expect(payload["resumable"] as? Bool == false)
        }
    }

    @Test func sessionCloseWithoutIdUsesBoundHintAmongMultipleActiveSessions() async throws {
        try await withBroker { broker in
            let hint = MCPClientSessionHint()
            let firstID = try await open(broker, hint: hint)
            _ = try await open(broker, hint: MCPClientSessionHint())
            let closed = await WaxMCPTools.handleCall(
                params: .init(name: "session_close", arguments: [
                    "content": .string("close bound session without repeating uuid"),
                ]),
                broker: broker,
                sessionHint: hint
            )
            #expect(closed.isError != true)
            #expect(try json(closed)["session_id"] as? String == firstID)
            #expect(hint.current() == nil)
        }
    }

    @Test func sessionCloseWithoutIdSurvivesHintDropViaConnectionRegistry() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withBroker { broker in
            let key = "http-\(UUID().uuidString)"
            let firstHint = MCPClientSessionHint(connectionKey: key)
            let sessionID = try await open(broker, hint: firstHint)
            _ = try await open(broker, hint: MCPClientSessionHint())
            let recoveredHint = MCPClientSessionHint(connectionKey: key)
            #expect(recoveredHint.current() == sessionID)
            let closed = await WaxMCPTools.handleCall(
                params: .init(name: "session_close", arguments: [
                    "content": .string("close after HTTP server recreate"),
                ]),
                broker: broker,
                sessionHint: recoveredHint
            )
            #expect(closed.isError != true)
            #expect(try json(closed)["session_id"] as? String == sessionID)
        }
    }
}
#endif
