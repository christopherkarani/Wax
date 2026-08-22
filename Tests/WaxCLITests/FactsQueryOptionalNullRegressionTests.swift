import Foundation
import Testing
@testable import Wax
import WaxCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Regression: `facts-query` with omitted optional filters used to fail with
/// "subject must be a string" because the broker treated JSON null as invalid.
@Test
func factsQueryWithoutFiltersSucceedsViaCLI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WaxCLITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo
    let candidates = [
        repoRoot.appendingPathComponent(".build/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/wax-cli"),
        repoRoot.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/wax-cli"),
    ]
    let binary = try #require(candidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    })

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("facts-null-\(UUID().uuidString)", isDirectory: true)
    let store = root.appendingPathComponent("store.wax")
    let brokerDir = root.appendingPathComponent("broker", isDirectory: true)
    let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: brokerDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func run(_ args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["WAX_BROKER_DIR"] = brokerDir.path
        environment["WAX_SESSION_ROOT"] = sessionRoot.path
        environment["WAX_BROKER_START_TIMEOUT_SECS"] = "30"
        environment["WAX_BROKER_IDLE_TIMEOUT_SECS"] = "60"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    let storePath = store.path
    let assert = try run([
        "fact-assert", "--store-path", storePath, "--no-embedder",
        "--subject", "user", "--predicate", "prefers", "--object", "Helix",
    ])
    #expect(assert.0 == 0, Comment(rawValue: "fact-assert failed: \(assert.1)"))

    let queryAll = try run([
        "facts-query", "--store-path", storePath, "--no-embedder",
    ])
    #expect(queryAll.0 == 0, Comment(rawValue: "facts-query failed: \(queryAll.1)"))
    #expect(
        queryAll.1.localizedCaseInsensitiveContains("Helix")
            || queryAll.1.localizedCaseInsensitiveContains("prefers")
            || queryAll.1.localizedCaseInsensitiveContains("user")
            || queryAll.1.localizedCaseInsensitiveContains("fact"),
        Comment(rawValue: queryAll.1)
    )
}

@Test
func brokerStartTimeoutTerminatesLaunchedProcess() async throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("broker-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let pidFile = temp.appendingPathComponent("daemon.pid")
    let script = temp.appendingPathComponent("hanging-broker")
    let scriptBody = """
    #!/bin/sh
    echo $$ > '\(pidFile.path)'
    exec sleep 60
    """
    try scriptBody.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let configuration = AgentBrokerConfiguration(
        brokerExecutablePath: script.path,
        storePath: temp.appendingPathComponent("store.wax").path,
        sessionRootPath: temp.appendingPathComponent("sessions").path,
        socketPath: temp.appendingPathComponent("broker.sock").path,
        embedderChoice: "none",
        noEmbedder: true,
        requireVector: false,
        embedderTuning: CommandLineEmbedderRuntimeTuning()
    )

    await #expect(throws: Error.self) {
        _ = try await AgentBrokerClient.ensureAvailable(
            configuration: configuration,
            startTimeoutSecondsOverride: 0.4
        )
    }

    let pidText = (try? String(contentsOf: pidFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = pidText.flatMap(Int32.init)
    if let pid, pid > 0 {
        #expect(kill(pid, 0) != 0, "timed-out broker process \(pid) must not keep running")
    }
}
