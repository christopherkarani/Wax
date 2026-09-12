import Foundation
import Testing
@testable import Wax
@testable import wax_cli

struct MCPRunHookTests {
    @Test func stdinParserReadsHostSessionAndCwd() {
        let data = Data("""
        {
          "hook_event_name": "SessionStart",
          "session_id": "chat-42",
          "cwd": "/tmp/wax-hook"
        }
        """.utf8)
        let event = HostHookStdinParser.parse(data)
        #expect(event.eventName == "SessionStart")
        #expect(event.conversationID == "chat-42")
        #expect(event.cwd == "/tmp/wax-hook")
    }

    @Test func stopIdleAndCompactNeverClose() {
        #expect(HostHookStdinParser.isNeverClose("Stop"))
        #expect(HostHookStdinParser.isNeverClose("stop"))
        #expect(HostHookStdinParser.isNeverClose("session.idle"))
        #expect(HostHookStdinParser.isNeverClose("session.compacted"))
        #expect(HostHookStdinParser.isNeverClose("experimental.session.compacting"))
        #expect(HostHookStdinParser.isNeverClose("session.status"))
        #expect(HostHookStdinParser.isNeverClose("SessionStart") == false)
        #expect(HostHookStdinParser.isNeverClose("SessionEnd") == false)
    }

    @Test func checkpointOnSessionEndSkipsCleanlyWhenNothingIsBound() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-run-hook-end-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data("""
        {"hook_event_name":"SessionEnd","session_id":"chat-gone","cwd":"\(root.path)"}
        """.utf8)
        let outcome = MCPRunHookRunner.run(
            host: "claude",
            role: "checkpoint",
            stdin: data,
            storePath: root.appendingPathComponent("missing.wax").path,
            noEmbedder: true
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.stdout.contains("no_bound_session"))
    }

    @Test func checkpointWithEmptyConversationIDSkipsInsteadOfMatching() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-run-hook-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data("""
        {"hook_event_name":"SessionEnd","session_id":"","cwd":"\(root.path)"}
        """.utf8)
        let outcome = MCPRunHookRunner.run(
            host: "claude",
            role: "checkpoint",
            stdin: data,
            storePath: root.appendingPathComponent("missing.wax").path,
            noEmbedder: true
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.stdout.contains("no_bound_session"))
    }

    @Test func checkpointOnStopIsNoOp() {
        let data = Data("""
        {"hook_event_name":"Stop","session_id":"chat-1","cwd":"/tmp/repo"}
        """.utf8)
        let outcome = MCPRunHookRunner.run(host: "claude", role: "checkpoint", stdin: data)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr.isEmpty)
    }

    @Test func primeWithoutBrokerExitsZeroWithHostEnvelopeAndNoStderr() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-run-hook-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data("""
        {"hook_event_name":"SessionStart","session_id":"chat-1","cwd":"\(root.path)"}
        """.utf8)
        let outcome = MCPRunHookRunner.run(
            host: "claude",
            role: "prime",
            stdin: data,
            storePath: root.appendingPathComponent("missing.wax").path,
            noEmbedder: true
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.stdout.contains("additionalContext"))
        #expect(outcome.stdout.contains("session_id") == false)
    }

    @Test func unknownRoleIsSilentSuccess() {
        let outcome = MCPRunHookRunner.run(host: "claude", role: "unknown", stdin: Data())
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr.isEmpty)
    }
}
