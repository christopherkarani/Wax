import Foundation
import Testing
@testable import Wax
@testable import WaxCore
@testable import wax_cli

struct MCPCheckpointTests {
    @Test func checkpointCommandParsesSessionAndHostKeyFlags() throws {
        let byID = try WaxCLI.MCP.Checkpoint.parse([
            "--session-id", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "--content-file", "/tmp/handoff.txt",
        ])
        #expect(byID.sessionID == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(byID.contentFile == "/tmp/handoff.txt")
        #expect(byID.strict == false)

        let hostKey = try WaxCLI.MCP.Checkpoint.parse([
            "--host", "claude",
            "--conversation-id", "chat-1",
            "--cwd", "/tmp/repo",
            "--strict",
        ])
        #expect(hostKey.host == .claude)
        #expect(hostKey.conversationID == "chat-1")
        #expect(hostKey.cwd == "/tmp/repo")
        #expect(hostKey.strict)
    }

    @Test func cwdOnlyCheckpointSkipsWithoutSelectingASession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        try saveManifest(
            makeManifest(
                sessionID: UUID(),
                conversationID: "claude:chat-a",
                project: root.url.lastPathComponent,
                repo: root.url.lastPathComponent
            ),
            rootURL: root.sessions
        )
        let outcome = MCPCheckpointRunner.run(
            MCPCheckpointRunner.Request(
                sessionID: nil,
                host: nil,
                conversationID: nil,
                cwd: root.url.path,
                contentFile: nil,
                strict: false,
                timeoutSeconds: 1.5,
                storePath: root.store.path,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: root.configuration,
                sessionRootURL: root.sessions
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        let object = try #require(jsonObject(outcome.stdout))
        #expect(object["status"] as? String == "skipped")
        #expect(object["reason"] as? String == "no_bound_session")
    }

    @Test func hostKeyWithNoMatchSkipsNoBoundSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let outcome = MCPCheckpointRunner.run(
            MCPCheckpointRunner.Request(
                sessionID: nil,
                host: "claude",
                conversationID: "missing-chat",
                cwd: root.url.path,
                contentFile: nil,
                strict: false,
                timeoutSeconds: 1.5,
                storePath: root.store.path,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: root.configuration,
                sessionRootURL: root.sessions
            )
        )
        #expect(outcome.exitCode == 0)
        let object = try #require(jsonObject(outcome.stdout))
        #expect(object["status"] as? String == "skipped")
        #expect(object["reason"] as? String == "no_bound_session")
        #expect(object["already_ended"] as? Bool == false)
    }

    @Test func multipleLiveHostMatchesAreAmbiguousAndStrictExitsNonzero() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let wire = HostConversationKey(
            hostNamespace: "claude",
            conversationID: "dup-chat",
            repoIdentity: root.url.lastPathComponent
        ).wireConversationID
        try saveManifest(
            makeManifest(
                sessionID: UUID(),
                runID: "a",
                conversationID: wire,
                project: root.url.lastPathComponent,
                repo: root.url.lastPathComponent
            ),
            rootURL: root.sessions
        )
        try saveManifest(
            makeManifest(
                sessionID: UUID(),
                runID: "b",
                conversationID: wire,
                project: root.url.lastPathComponent,
                repo: root.url.lastPathComponent
            ),
            rootURL: root.sessions
        )

        let skipped = MCPCheckpointRunner.run(
            hostKeyRequest(root: root, conversationID: "dup-chat", strict: false)
        )
        #expect(skipped.exitCode == 0)
        #expect(jsonObject(skipped.stdout)?["reason"] as? String == "ambiguous_identity")

        let strict = MCPCheckpointRunner.run(
            hostKeyRequest(root: root, conversationID: "dup-chat", strict: true)
        )
        #expect(strict.exitCode != 0)
        #expect(strict.stderr.isEmpty)
        #expect(jsonObject(strict.stdout)?["reason"] as? String == "ambiguous_identity")
    }

    @Test func repeatedHostKeyCheckpointReportsAlreadyEnded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let sessionID = UUID()
        let wire = HostConversationKey(
            hostNamespace: "claude",
            conversationID: "ended-chat",
            repoIdentity: root.url.lastPathComponent
        ).wireConversationID
        try saveManifest(
            makeManifest(
                sessionID: sessionID,
                conversationID: wire,
                project: root.url.lastPathComponent,
                repo: root.url.lastPathComponent,
                status: .ended
            ),
            rootURL: root.sessions
        )
        let first = MCPCheckpointRunner.run(
            hostKeyRequest(root: root, conversationID: "ended-chat", strict: false)
        )
        let second = MCPCheckpointRunner.run(
            hostKeyRequest(root: root, conversationID: "ended-chat", strict: false)
        )
        for outcome in [first, second] {
            #expect(outcome.exitCode == 0)
            let object = try #require(jsonObject(outcome.stdout))
            #expect(object["status"] as? String == "ok")
            #expect(object["already_ended"] as? Bool == true)
        }
    }

    @Test func activeHostKeyWithoutBrokerSkipsUnavailableUnlessStrict() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let wire = HostConversationKey(
            hostNamespace: "claude",
            conversationID: "live-chat",
            repoIdentity: root.url.lastPathComponent
        ).wireConversationID
        try saveManifest(
            makeManifest(
                sessionID: UUID(),
                conversationID: wire,
                project: root.url.lastPathComponent,
                repo: root.url.lastPathComponent
            ),
            rootURL: root.sessions
        )
        let skipped = MCPCheckpointRunner.run(
            hostKeyRequest(root: root, conversationID: "live-chat", strict: false)
        )
        let object = try #require(jsonObject(skipped.stdout))
        #expect(skipped.exitCode == 0)
        #expect(object["reason"] as? String == "broker_unavailable")
        #expect((object["lease_seconds"] as? Int) == 300
            || (object["lease_seconds"] as? Int64) == 300)
        #expect(VirtualSessionStore.defaultSessionLeaseSeconds == 300)

        let strict = MCPCheckpointRunner.run(
            hostKeyRequest(root: root, conversationID: "live-chat", strict: true)
        )
        #expect(strict.exitCode != 0)
        #expect(strict.stderr.isEmpty)
    }

    @Test func sessionIDCloseUsesProbeAndRepeatIsAlreadyEnded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let sessionID = UUID()
        let closes = LockBox(0)
        let probe: @Sendable (AgentBrokerRequest, AgentBrokerConfiguration, TimeInterval) throws -> AgentBrokerResponse? = { request, _, _ in
            #expect(request.command == "session_close")
            closes.value += 1
            return AgentBrokerResponse.success(
                payload: .object([
                    "status": .string("ok"),
                    "already_ended": .bool(closes.value > 1),
                    "session_id": .string(sessionID.uuidString),
                ])
            )
        }
        let first = MCPCheckpointRunner.run(
            MCPCheckpointRunner.Request(
                sessionID: sessionID.uuidString,
                host: nil,
                conversationID: nil,
                cwd: nil,
                contentFile: nil,
                strict: false,
                timeoutSeconds: 1.5,
                storePath: root.store.path,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: root.configuration,
                probe: probe,
                sessionRootURL: root.sessions
            )
        )
        try saveManifest(
            makeManifest(
                sessionID: sessionID,
                conversationID: "claude:x",
                project: root.url.lastPathComponent,
                repo: root.url.lastPathComponent,
                status: .ended
            ),
            rootURL: root.sessions
        )
        let second = MCPCheckpointRunner.run(
            MCPCheckpointRunner.Request(
                sessionID: sessionID.uuidString,
                host: nil,
                conversationID: nil,
                cwd: nil,
                contentFile: nil,
                strict: false,
                timeoutSeconds: 1.5,
                storePath: root.store.path,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: root.configuration,
                probe: probe,
                sessionRootURL: root.sessions
            )
        )
        #expect(first.exitCode == 0)
        #expect(jsonObject(first.stdout)?["already_ended"] as? Bool == false)
        #expect(second.exitCode == 0)
        #expect(jsonObject(second.stdout)?["already_ended"] as? Bool == true)
        #expect(closes.value == 1)
    }

    @Test func contentFileIsBoundedHandoffNotTranscriptIngest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let file = root.url.appendingPathComponent("handoff.txt")
        let oversized = String(repeating: "t", count: BrokerLimits.maxSessionOpenHandoffContentBytes + 64)
        try oversized.write(to: file, atomically: true, encoding: .utf8)
        let captured = LockBox("")
        let sessionID = UUID()
        let outcome = MCPCheckpointRunner.run(
            MCPCheckpointRunner.Request(
                sessionID: sessionID.uuidString,
                host: nil,
                conversationID: nil,
                cwd: nil,
                contentFile: file.path,
                strict: false,
                timeoutSeconds: 1.5,
                storePath: root.store.path,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: root.configuration,
                probe: { request, _, _ in
                    captured.value = request.arguments["content"]?.stringValue ?? ""
                    #expect(request.command == "session_close")
                    return AgentBrokerResponse.success(
                        payload: .object(["already_ended": .bool(false)])
                    )
                },
                sessionRootURL: root.sessions
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(captured.value.utf8.count <= BrokerLimits.maxSessionOpenHandoffContentBytes)
        #expect(captured.value.isEmpty == false)
        #expect(outcome.stderr.isEmpty)
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private struct CheckpointRoot {
    var url: URL
    var store: URL
    var sessions: URL
    var configuration: AgentBrokerConfiguration
}

private func makeRoot() throws -> CheckpointRoot {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-checkpoint-\(UUID().uuidString)", isDirectory: true)
    let store = url.appendingPathComponent("store.wax")
    let sessions = url.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: url.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    let configuration = AgentBrokerConfiguration(
        brokerExecutablePath: "/usr/bin/true",
        storePath: store.path,
        sessionRootPath: sessions.path,
        socketPath: url.appendingPathComponent("missing.sock").path,
        embedderChoice: "minilm",
        noEmbedder: true,
        requireVector: false,
        embedderTuning: CommandLineEmbedderRuntimeTuning()
    )
    return CheckpointRoot(url: url, store: store, sessions: sessions, configuration: configuration)
}

private func hostKeyRequest(
    root: CheckpointRoot,
    conversationID: String,
    strict: Bool
) -> MCPCheckpointRunner.Request {
    MCPCheckpointRunner.Request(
        sessionID: nil,
        host: "claude",
        conversationID: conversationID,
        cwd: root.url.path,
        contentFile: nil,
        strict: strict,
        timeoutSeconds: 1.5,
        storePath: root.store.path,
        noEmbedder: true,
        embedderChoice: "minilm",
        configuration: root.configuration,
        sessionRootURL: root.sessions
    )
}

private func makeManifest(
    sessionID: UUID,
    runID: String = "run",
    conversationID: String,
    project: String?,
    repo: String?,
    status: BrokerSessionManifest.Status = .active
) -> BrokerSessionManifest {
    BrokerSessionManifest(
        sessionID: sessionID,
        agentID: "agent",
        runID: runID,
        project: project,
        repo: repo,
        storePath: "/tmp/\(sessionID.uuidString).wax",
        eventLogPath: "/tmp/\(sessionID.uuidString).events.jsonl",
        status: status,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: 1,
        updatedAtMs: 1,
        conversationID: conversationID
    )
}

private func saveManifest(_ manifest: BrokerSessionManifest, rootURL: URL) throws {
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: manifest.sessionID)
    )
}

private func jsonObject(_ stdout: String) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) else {
        return nil
    }
    return object as? [String: Any]
}
