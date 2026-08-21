import Foundation
import Testing
@testable import Wax

struct BrokerCommandDecodeTests {
    @Test
    func rememberAliasSharesPayloadShape() throws {
        let args: [String: AgentBrokerValue] = [
            "content": .string("  keep spaces  "),
            "session_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            "scope": .string("session"),
            "memory_type": .string("decision"),
            "durability": .string("working"),
        ]
        let remember = try BrokerCommand.decode(command: "remember", arguments: args)
        let append = try BrokerCommand.decode(command: "memory_append", arguments: args)
        guard case .remember(let a) = remember, case .memoryAppend(let b) = append else {
            Issue.record("alias mismatch")
            return
        }
        #expect(a == b)
        #expect(a.content == "  keep spaces  ")
        #expect(a.sessionID == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(a.writeScope == .session)
        #expect(a.writeSemantics.type == .decision)
    }

    @Test
    func rememberRejectsUnknownArgument() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "remember",
                arguments: [
                    "content": .string("x"),
                    "unexpected": .string("y"),
                ]
            )
        }
    }

    @Test
    func rememberScopeSessionRequiresSessionID() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "remember",
                arguments: [
                    "content": .string("x"),
                    "scope": .string("session"),
                ]
            )
        }
    }

    @Test
    func recallDefaultsAndModeRules() throws {
        let decoded = try BrokerCommand.decode(
            command: "recall",
            arguments: ["query": .string("what happened")]
        )
        guard case .recall(let payload) = decoded else {
            Issue.record("expected recall")
            return
        }
        #expect(payload.query == "what happened")
        #expect(payload.limit == 5)
        #expect(payload.searchTopK == 5)
        #expect(payload.scope == .project)
        #expect(payload.mode == nil)
    }

    @Test
    func recallRejectsAlphaUnlessHybrid() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "recall",
                arguments: [
                    "query": .string("q"),
                    "mode": .string("text"),
                    "alpha": .double(0.2),
                ]
            )
        }
    }

    @Test
    func recallAcceptsHybridAlpha() throws {
        let decoded = try BrokerCommand.decode(
            command: "recall",
            arguments: [
                "query": .string("q"),
                "mode": .string("hybrid"),
                "alpha": .double(0.25),
                "search_top_k": .int(7),
                "limit": .int(3),
            ]
        )
        guard case .recall(let payload) = decoded else {
            Issue.record("expected recall")
            return
        }
        #expect(payload.mode == .hybrid(alpha: 0.25))
        #expect(payload.limit == 3)
        #expect(payload.searchTopK == 7)
    }

    @Test
    func searchDefaultsModeToText() throws {
        let decoded = try BrokerCommand.decode(
            command: "search",
            arguments: ["query": .string("needle")]
        )
        guard case .search(let payload) = decoded else {
            Issue.record("expected search")
            return
        }
        #expect(payload.mode == .textOnly)
        #expect(payload.topK == 10)
    }

    @Test
    func memorySearchIsDistinctFromSearch() throws {
        let decoded = try BrokerCommand.decode(
            command: "memory_search",
            arguments: [
                "query": .string("needle"),
                "include_working": .bool(false),
                "include_episodic": .bool(false),
                "include_durable": .bool(true),
            ]
        )
        guard case .memorySearch(let payload) = decoded else {
            Issue.record("expected memory_search")
            return
        }
        #expect(payload.includeWorking == false)
        #expect(payload.includeEpisodic == false)
        #expect(payload.includeDurable == true)
        #expect(payload.mode == .textOnly)
    }

    @Test
    func sessionAndHandoffDecode() throws {
        let start = try BrokerCommand.decode(
            command: "session_start",
            arguments: [
                "agent_id": .string("agent"),
                "run_id": .string("run"),
            ]
        )
        guard case .sessionStart(let startPayload) = start else {
            Issue.record("expected session_start")
            return
        }
        #expect(startPayload.agentID == "agent")
        #expect(startPayload.runID == "run")

        let handoff = try BrokerCommand.decode(
            command: "handoff",
            arguments: [
                "content": .string("summary"),
                "pending_tasks": .array([.string("one"), .string("two")]),
            ]
        )
        guard case .handoff(let handoffPayload) = handoff else {
            Issue.record("expected handoff")
            return
        }
        #expect(handoffPayload.content == "summary")
        #expect(handoffPayload.pendingTasks == ["one", "two"])

        let latest = try BrokerCommand.decode(
            command: "handoff_latest",
            arguments: ["project": .string("Wax")]
        )
        guard case .handoffLatest(let latestPayload) = latest else {
            Issue.record("expected handoff_latest")
            return
        }
        #expect(latestPayload.project == "Wax")
    }

    @Test
    func unmigratedCommandsPassthroughAfterSurfaceValidation() throws {
        let decoded = try BrokerCommand.decode(command: "stats", arguments: [:])
        guard case .passthrough(let command, let arguments) = decoded else {
            Issue.record("expected passthrough")
            return
        }
        #expect(command == "stats")
        #expect(arguments.isEmpty)
    }

    @Test
    func emptyRecallQueryRejected() {
        #expect(throws: BrokerValidationError.self) {
            _ = try BrokerCommand.decode(
                command: "recall",
                arguments: ["query": .string("   ")]
            )
        }
    }
}
