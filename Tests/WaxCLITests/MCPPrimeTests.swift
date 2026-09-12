import Foundation
import Dispatch
import Testing
@testable import Wax
@testable import WaxCore
@testable import wax_cli

struct MCPPrimeTests {
    @Test func primeCommandParsesHostCwdAndFormatFlags() throws {
        let command = try WaxCLI.MCP.Prime.parse([
            "--host", "claude",
            "--cwd", "/tmp/wax-prime",
            "--format", "cursor",
            "--include-person",
        ])
        #expect(command.host == .claude)
        #expect(command.cwd == "/tmp/wax-prime")
        #expect(command.format == .cursor)
        #expect(command.includePerson)
        #expect(command.timeoutSeconds == MCPPrimeRunner.defaultTimeoutSeconds)

        // The global person lane stays off unless the operator opts in.
        let minimal = try WaxCLI.MCP.Prime.parse([
            "--host", "claude",
            "--cwd", "/tmp/wax-prime",
        ])
        #expect(!minimal.includePerson)
    }

    @Test func primeBrokerDownExitsZeroWithEmptyValidResultAndNoStderr() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-prime-down-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let startedFlag = root.appendingPathComponent("started")
        let canary = root.appendingPathComponent("canary-broker")
        try """
        #!/bin/sh
        echo started > '\(startedFlag.path)'
        exit 1
        """.write(to: canary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canary.path)

        let configuration = AgentBrokerConfiguration(
            brokerExecutablePath: canary.path,
            storePath: root.appendingPathComponent("store.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            socketPath: root.appendingPathComponent("missing.sock").path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            embedderTuning: CommandLineEmbedderRuntimeTuning()
        )

        let started = Date()
        let outcome = MCPPrimeRunner.run(
            MCPPrimeRunner.Request(
                host: "claude",
                cwd: root.path,
                includePerson: true,
                format: .json,
                timeoutSeconds: 1.5,
                storePath: configuration.storePath,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: configuration
            )
        )
        // Well under the 10s broker-start timeout: proves no broker was started,
        // with margin for loaded CI runners.
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(FileManager.default.fileExists(atPath: startedFlag.path) == false)
        #expect(FileManager.default.fileExists(atPath: configuration.socketPath) == false)

        let raw = try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8))
        let object = try #require(raw as? [String: Any])
        #expect(object["schema_version"] as? String == MCPPrimeAssembly.schemaVersion)
        #expect(object["ownership_level"] as? String == "B")
        #expect(object["share_prompt"] == nil)
        #expect(object["session_id"] == nil)
        #expect((object["person"] as? [Any])?.isEmpty == true)
        #expect((object["project_memories"] as? [Any])?.isEmpty == true)
        #expect(outcome.stdout.contains(MCPPrimeAssembly.trustHeader) == false)
    }

    @Test func fiveConcurrentPrimesWithBrokerDownStaySilentAndStartNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-prime-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let startedFlag = root.appendingPathComponent("started")
        let canary = root.appendingPathComponent("canary-broker")
        try """
        #!/bin/sh
        echo started > '\(startedFlag.path)'
        exit 1
        """.write(to: canary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canary.path)

        let configuration = AgentBrokerConfiguration(
            brokerExecutablePath: canary.path,
            storePath: root.appendingPathComponent("store.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            socketPath: root.appendingPathComponent("missing.sock").path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            embedderTuning: CommandLineEmbedderRuntimeTuning()
        )

        let outcomes = LockBox<[MCPPrimeOutcome]>([])
        let started = Date()
        DispatchQueue.concurrentPerform(iterations: 5) { _ in
            let outcome = MCPPrimeRunner.run(
                MCPPrimeRunner.Request(
                    host: "cursor",
                    cwd: root.path,
                    includePerson: false,
                    format: .claude,
                    timeoutSeconds: 1.5,
                    storePath: configuration.storePath,
                    noEmbedder: true,
                    embedderChoice: "minilm",
                    configuration: configuration
                )
            )
            outcomes.value.append(outcome)
        }
        // Same bound rationale as the single-prime test: proves no broker start.
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(outcomes.value.count == 5)
        #expect(outcomes.value.allSatisfy { $0.exitCode == 0 && $0.stderr.isEmpty })
        #expect(outcomes.value.allSatisfy { !$0.stdout.contains(MCPPrimeAssembly.trustHeader) })
        #expect(FileManager.default.fileExists(atPath: startedFlag.path) == false)
    }

    @Test func primeHostFormatsBeginWithTrustHeaderWhenProbeReturnsHits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-prime-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let project = root.lastPathComponent
        let payload = AgentBrokerResponse.success(
            payload: .object([
                "project_miss": .bool(false),
                "project": .string(project),
                "repo": .string(project),
                "results": .array([
                    .object([
                        "text": .string("Keep prime read-only."),
                        "memory_type": .string("lesson"),
                        "project": .string(project),
                        "score": .double(1.0),
                        "created_at_ms": .int(1),
                    ]),
                ]),
            ])
        )

        let configuration = AgentBrokerConfiguration(
            brokerExecutablePath: "/usr/bin/true",
            storePath: root.appendingPathComponent("store.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            socketPath: root.appendingPathComponent("missing.sock").path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            embedderTuning: CommandLineEmbedderRuntimeTuning()
        )
        let outcome = MCPPrimeRunner.run(
            MCPPrimeRunner.Request(
                host: "claude",
                cwd: root.path,
                includePerson: false,
                format: .claude,
                timeoutSeconds: 1.5,
                storePath: configuration.storePath,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: configuration,
                probe: { request, _, _ in
                    #expect(request.command != "session_open")
                    if request.command == "recall" {
                        return payload
                    }
                    return AgentBrokerResponse.success(payload: .object(["found": .bool(false)]))
                }
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        let raw = try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8))
        let object = try #require(raw as? [String: Any])
        let hook = try #require(object["hookSpecificOutput"] as? [String: Any])
        let context = try #require(hook["additionalContext"] as? String)
        #expect(context.hasPrefix(MCPPrimeAssembly.trustHeader))
        #expect(context.contains("Keep prime read-only."))
    }

    @Test func primeLiveBrokerProbeDoesNotStartASecondWriter() async throws {
        let binary = try #require(waxCLIBinary())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-prime-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let token = UUID().uuidString.prefix(8)
        let store = root.appendingPathComponent("store.wax")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let socket = URL(fileURLWithPath: "/tmp/wxp-\(token).sock")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socket) }

        let configuration = AgentBrokerConfiguration(
            brokerExecutablePath: binary.path,
            storePath: store.path,
            sessionRootPath: sessions.path,
            socketPath: socket.path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            embedderTuning: CommandLineEmbedderRuntimeTuning()
        )
        let started = try await AgentBrokerClient.ensureAvailable(configuration: configuration)
        #expect(started)
        defer {
            try? AgentBrokerClient.shutdownOwnedBrokerIfReachable(configuration: configuration)
        }

        let remembered = try AgentBrokerClient.probe(
                request: AgentBrokerRequest(
                    command: "remember",
                    arguments: [
                        "content": .string("Prime must reuse the long-lived broker socket."),
                        "memory_type": .string("lesson"),
                        "project": .string(root.lastPathComponent),
                        "cwd": .string(root.path),
                    ]
                ),
                configuration: configuration,
                timeoutSeconds: 8
            )
        let rememberedOK = try #require(remembered)
        #expect(rememberedOK.ok)

        let outcome = MCPPrimeRunner.run(
            MCPPrimeRunner.Request(
                host: "claude",
                cwd: root.path,
                includePerson: false,
                format: .json,
                timeoutSeconds: 1.5,
                storePath: store.path,
                noEmbedder: true,
                embedderChoice: "minilm",
                configuration: configuration
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.stdout.contains("Prime must reuse the long-lived broker socket."))

        let reused = try await AgentBrokerClient.ensureAvailable(configuration: configuration)
        #expect(reused == false)
        #expect(FileManager.default.fileExists(atPath: socket.path))
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

private func waxCLIBinary() -> URL? {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repoRoot.appendingPathComponent(".build/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/wax-cli"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}
