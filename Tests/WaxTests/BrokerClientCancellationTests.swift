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

    let mute = root.appendingPathComponent("mute-broker")
    try """
    #!/bin/sh
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

    // The launch hook is the handshake, so there is no deadline to race.
    let (launches, launched) = AsyncStream.makeStream(of: pid_t.self)
    let start = Task {
        defer { launched.finish() }
        return try await AgentBrokerClient.ensureAvailable(
            configuration: configuration,
            // Far past any scheduler stall, so the start ends by cancellation.
            startTimeoutSecondsOverride: 600,
            onBrokerLaunched: { launched.yield($0) }
        )
    }
    guard let pid = await launches.first(where: { _ in true }) else {
        _ = try await start.value
        Issue.record("ensureAvailable returned without launching a broker")
        return
    }
    start.cancel()
    await #expect(throws: CancellationError.self) { try await start.value }

    // A cancelled start returns only after the child is reaped.
    let survived = kill(pid, 0) == 0
    if survived {
        kill(pid, SIGKILL)
    }
    #expect(!survived, "launched broker \(pid) survived a cancelled start")
}
#endif
