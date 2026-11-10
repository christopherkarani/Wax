#if canImport(Darwin)
import Foundation
import Testing
@testable import WaxCore

/// Blocking work is mostly waiting (a child process, a socket, a sleep), so a
/// call must start even while other blocking calls keep every core busy. On a
/// shared queue, which GCD caps at a few threads per core, a parallel test run kept the
/// work of a 0.1 s CLI call waiting about 50 s to start, and a CI runner pushed
/// that past the parity test's 2-minute limit.
///
/// The busy calls are blocking work themselves and stop as soon as the probe
/// starts, so a passing run holds the cores for milliseconds, not seconds.
@Test func blockingWorkStartsWhileOtherBlockingWorkHoldsEveryCore() async throws {
    let spin = SpinControl()
    let cores = ProcessInfo.processInfo.activeProcessorCount
    // Twice the cores: on a 14-core Mac the old shared queue ran 28 and no more.
    let spinners = (0..<(cores * 2)).map { _ in
        Task {
            await BlockingWork.run {
                spin.markStarted()
                // Stops on its own, so a starved probe fails the test instead of hanging it.
                let stop = ContinuousClock.now.advanced(by: .seconds(10))
                while !spin.isReleased, ContinuousClock.now < stop {}
            }
        }
    }
    defer { spin.release() }
    try await waitUntil(seconds: 5) { spin.startedCount >= cores }

    let probe = Task { await BlockingWork.run { spin.markProbeStarted() } }
    let probeStarted = try await waitUntil(seconds: 2) { spin.probeStarted }
    spin.release()
    await probe.value
    for spinner in spinners {
        await spinner.value
    }

    #expect(probeStarted, "a blocking call waited for a core while \(spin.startedCount) others ran")
}

/// Polls `condition` until it holds or `seconds` pass. Returns whether it held.
@discardableResult
private func waitUntil(seconds: Int, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private final class SpinControl: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var started = 0
    private var probe = false

    var isReleased: Bool { lock.withLock { released } }

    var startedCount: Int { lock.withLock { started } }

    var probeStarted: Bool { lock.withLock { probe } }

    func markStarted() { lock.withLock { started += 1 } }

    func markProbeStarted() { lock.withLock { probe = true } }

    func release() { lock.withLock { released = true } }
}
#endif
