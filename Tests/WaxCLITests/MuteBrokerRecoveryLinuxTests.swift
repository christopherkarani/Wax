#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import Wax
import WaxCore

/// A `wax-cli` broker that holds its socket but never answers is replaced: the
/// client identifies it through the socket's peer credentials and
/// `/proc/<pid>/exe`, stops it, and starts a fresh broker.
///
/// The broker is made mute with SIGSTOP. A stopped process keeps its listening
/// socket, so connects still succeed and every request goes unanswered.
@Test(.timeLimit(.minutes(2)))
func muteWaxCLIBrokerIsReplacedOnLinux() async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("wxmb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let configuration = AgentBrokerConfiguration(
        brokerExecutablePath: try siblingWaxCLIPath(),
        storePath: root.appendingPathComponent("store.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        socketPath: root.appendingPathComponent("broker.sock").path,
        embedderChoice: "minilm",
        noEmbedder: true,
        requireVector: false,
        embedderTuning: CommandLineEmbedderRuntimeTuning()
    )
    defer { try? AgentBrokerClient.shutdownOwnedBrokerIfReachable(configuration: configuration) }

    let firstLaunch = LaunchedPIDs()
    let startedFirst = try await AgentBrokerClient.ensureAvailable(
        configuration: configuration,
        onBrokerLaunched: { (pid: pid_t) in firstLaunch.record(pid) }
    )
    let mute = try #require(firstLaunch.pids.first)
    #expect(startedFirst)
    #expect(await AgentBrokerClient.ownedBrokerPeerPIDOffPool(socketPath: configuration.socketPath) == mute)

    #expect(kill(mute, SIGSTOP) == 0)
    defer { kill(mute, SIGKILL) }

    let secondLaunch = LaunchedPIDs()
    let startedSecond = try await AgentBrokerClient.ensureAvailable(
        configuration: configuration,
        onBrokerLaunched: { (pid: pid_t) in secondLaunch.record(pid) }
    )
    let replacement = try #require(secondLaunch.pids.first)

    #expect(startedSecond)
    #expect(replacement != mute)
    #expect(kill(mute, 0) != 0, "the mute broker \(mute) is still running")
    let stats = try await AgentBrokerClient.probeOffPool(
        request: AgentBrokerRequest(id: "after-recovery", command: "stats"),
        configuration: configuration
    )
    #expect(stats?.ok == true)
}

/// `wax-cli` built beside this test binary. `/proc/self/exe` names the test
/// binary itself, so no `Bundle` lookup is needed.
private func siblingWaxCLIPath() throws -> String {
    let testBinary = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
    let sibling = testBinary.deletingLastPathComponent().appendingPathComponent("wax-cli").path
    return try #require(
        FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil,
        "wax-cli is not built beside \(testBinary.path)"
    )
}

private final class LaunchedPIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [pid_t] = []

    func record(_ pid: pid_t) {
        lock.withLock { recorded.append(pid) }
    }

    var pids: [pid_t] { lock.withLock { recorded } }
}
#endif
