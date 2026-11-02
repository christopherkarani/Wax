import Foundation
import Testing
@testable import Wax
#if canImport(Darwin)
import Darwin
#endif

@Test
func pollTimeoutRoundsSubMillisecondRemainderUp() {
    #expect(AgentBrokerClient.pollTimeoutMilliseconds(remaining: 0.0004) == 1)
    #expect(AgentBrokerClient.pollTimeoutMilliseconds(remaining: 0.0015) == 2)
    #expect(AgentBrokerClient.pollTimeoutMilliseconds(remaining: 2) == 2_000)
    #expect(AgentBrokerClient.pollTimeoutMilliseconds(remaining: 0) == 0)
    #expect(AgentBrokerClient.pollTimeoutMilliseconds(remaining: -1) == 0)
    #expect(AgentBrokerClient.pollTimeoutMilliseconds(remaining: 1e12) == Int32.max)
}

#if os(macOS)
/// A launched broker that never answers must not outlive a cancelled start.
@Test
func cancelledBrokerStartTerminatesTheLaunchedProcess() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-client-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let pidFile = root.appendingPathComponent("broker.pid")
    let mute = root.appendingPathComponent("mute-broker")
    try """
    #!/bin/sh
    echo $$ > '\(pidFile.path)'
    exec sleep 30
    """.write(to: mute, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mute.path)

    let configuration = AgentBrokerConfiguration(
        brokerExecutablePath: mute.path,
        storePath: root.appendingPathComponent("store.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        socketPath: root.appendingPathComponent("broker.sock").path,
        embedderChoice: "minilm",
        noEmbedder: true,
        requireVector: false,
        embedderTuning: .fromEnvironment()
    )

    let start = Task {
        try await AgentBrokerClient.ensureAvailable(
            configuration: configuration,
            startTimeoutSecondsOverride: 20
        )
    }
    let pid = try await waitForPID(in: pidFile, timeoutSeconds: 10)
    start.cancel()
    _ = await start.result

    let exited = await waitForExit(pid: pid, timeoutSeconds: 3)
    if !exited {
        kill(pid, SIGKILL)
    }
    #expect(exited, "launched broker \(pid) survived a cancelled start")
}

private func waitForPID(in file: URL, timeoutSeconds: TimeInterval) async throws -> pid_t {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let raw = try? String(contentsOf: file, encoding: .utf8),
           let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw BrokerNeverLaunched()
}

private struct BrokerNeverLaunched: Error {}

private func waitForExit(pid: pid_t, timeoutSeconds: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
#endif
