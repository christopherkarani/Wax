import Foundation
import Testing
import WaxCore
@testable import Wax

struct BrokerAdmissionTests {
    @Test(arguments: [
        (
            "session_end",
            "session_end",
            [String: AgentBrokerValue](),
            BrokerAdmission.rememberDrain
        ),
        (
            "session_close",
            "session_close",
            ["content": .string("done")],
            BrokerAdmission.rememberDrain
        ),
        (
            "task_state_migrate",
            "task_state_migrate",
            ["destination_path": .string("/tmp/wax-migrate")],
            BrokerAdmission.rememberDrain
        ),
        (
            "remember",
            "remember",
            ["content": .string("note")],
            BrokerAdmission.remember
        ),
        (
            "hybrid recall",
            "recall",
            ["query": .string("q"), "mode": .string("hybrid")],
            BrokerAdmission.embedderThenCommand
        ),
        (
            "omitted recall mode",
            "recall",
            ["query": .string("q")],
            BrokerAdmission.embedderThenCommand
        ),
        (
            "vector recall",
            "recall",
            ["query": .string("q"), "mode": .string("vector")],
            BrokerAdmission.embedderThenCommand
        ),
        (
            "text-only recall",
            "recall",
            ["query": .string("q"), "mode": .string("text")],
            BrokerAdmission.command
        ),
        (
            "hybrid search",
            "search",
            ["query": .string("q"), "mode": .string("hybrid")],
            BrokerAdmission.embedderThenCommand
        ),
        (
            "text-only search",
            "search",
            ["query": .string("q"), "mode": .string("text")],
            BrokerAdmission.command
        ),
        (
            "default search",
            "search",
            ["query": .string("q")],
            BrokerAdmission.command
        ),
        (
            "session_open with query",
            "session_open",
            ["recall_query": .string("prior work")],
            BrokerAdmission.embedderThenCommand
        ),
        (
            "session_open without query",
            "session_open",
            [:],
            BrokerAdmission.command
        ),
        (
            "session_open blank query",
            "session_open",
            ["recall_query": .string("   ")],
            BrokerAdmission.command
        ),
        (
            "hybrid memory_search",
            "memory_search",
            ["query": .string("q"), "mode": .string("hybrid")],
            BrokerAdmission.command
        ),
        (
            "flush",
            "flush",
            [:],
            BrokerAdmission.command
        ),
    ])
    func admissionFollowsDecodedCommand(
        _ name: String,
        _ wire: String,
        _ arguments: [String: AgentBrokerValue],
        _ expected: BrokerAdmission
    ) throws {
        let command = try BrokerCommand.decode(command: wire, arguments: arguments)
        #expect(BrokerAdmission.admission(for: command) == expected, "\(name)")
    }

    @Test
    func sessionOpenWhitespaceQuerySkipsEmbedderWait() {
        let command = BrokerCommand.sessionOpen(
            BrokerCommand.SessionOpen(
                project: nil,
                repo: nil,
                agentID: nil,
                runID: nil,
                recallQuery: " \n\t ",
                cwd: nil
            )
        )
        #expect(BrokerAdmission.admission(for: command) == .command)
    }

    @Test
    func sessionOpenNilQuerySkipsEmbedderWait() {
        let command = BrokerCommand.sessionOpen(
            BrokerCommand.SessionOpen(
                project: nil,
                repo: nil,
                agentID: nil,
                runID: nil,
                recallQuery: nil,
                cwd: nil
            )
        )
        #expect(BrokerAdmission.admission(for: command) == .command)
    }
}
