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
        brokerExecutablePath: try builtProductPath(named: "wax-cli"),
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
    // kill() only queues SIGSTOP. The kernel wakes one thread to start the group
    // stop, and until that thread is scheduled the others keep running and can
    // still answer a ping. The broker is mute only once every thread has stopped.
    try #require(
        await allThreadsStopped(pid: mute, within: .seconds(30)),
        "broker \(mute) did not stop after SIGSTOP: \(threadStates(pid: mute))"
    )

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

/// Polls until every thread of `pid` is in the stopped state ('T' in
/// `/proc/<pid>/task/<tid>/stat`), or `limit` passes. False for a process that
/// is gone, so a broker that died cannot pass as stopped.
private func allThreadsStopped(pid: pid_t, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while ContinuousClock.now < deadline {
        let states = threadStates(pid: pid)
        if !states.isEmpty, states.allSatisfy({ (state: Character) -> Bool in state == "T" }) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// One state letter per thread of `pid`, as `/proc/<pid>/task/<tid>/stat` reports
/// it. A thread that exits mid-scan is left out.
private func threadStates(pid: pid_t) -> String {
    let taskDirectory = "/proc/\(pid)/task"
    let threads = (try? FileManager.default.contentsOfDirectory(atPath: taskDirectory)) ?? []
    return String(threads.compactMap { (tid: String) -> Character? in
        guard let stat = try? String(contentsOfFile: "\(taskDirectory)/\(tid)/stat", encoding: .utf8),
              let commEnd = stat.lastIndex(of: ")") else {
            return nil
        }
        // "<tid> (<comm>) <state> ...": the comm may contain spaces or parentheses.
        return stat[stat.index(after: commEnd)...].first { (character: Character) -> Bool in character != " " }
    })
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
