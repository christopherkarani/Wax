#if canImport(Darwin)
import Foundation
import Testing
@testable import WaxCore

// Work that must start promptly on a loaded host: blocking work (mostly waiting
// on a child process, a socket or a sleep) and timeout deadlines. A queue GCD
// caps at one active thread per core starts neither while the cores are busy.
// In a parallel test run that kept a 0.1 s CLI call waiting about 50 s to start,
// and let a 1 s blocked operation finish before its 30 ms timeout fired.

/// Serialized: each test's spinners would hold the cores the other one waits for.
@Suite(.serialized)
struct BusyCoreSchedulingTests {
    @Test func blockingWorkStartsWhileEveryCoreIsBusy() async throws {
        let started = try await withEveryCoreBusy {
            let submitted = ContinuousClock.now
            let started = await BlockingWork.run { ContinuousClock.now }
            return submitted.duration(to: started)
        }
        // Starting is all that is measured; the bound only separates prompt from starved.
        #expect(started < .seconds(2))
    }

    @Test func asyncTimeoutFiresWhileEveryCoreIsBusy() async throws {
        try await withEveryCoreBusy {
            await #expect(throws: AsyncTimeout.TimeoutError.self) {
                // The operation blocks its thread for 3 s; the 30 ms timeout must fire first.
                _ = try await AsyncTimeout.run(timeout: .milliseconds(30), operation: "busy-cores") {
                    blockThread(for: 3)
                    return 0
                }
            }
        }
    }
}

/// `Thread.sleep` is unavailable in async code; the timeout is meant to escape a blocked thread.
private func blockThread(for seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// Runs `body` while spinners at user-initiated QoS hold every core. They stop
/// on their own after 10 s, so starved work fails a test instead of hanging it.
private func withEveryCoreBusy<T: Sendable>(
    _ body: () async throws -> T
) async throws -> T {
    let spin = SpinControl()
    let cores = ProcessInfo.processInfo.activeProcessorCount
    for _ in 0..<(cores * 2) {
        DispatchQueue.global(qos: .userInitiated).async {
            spin.markStarted()
            let stop = ContinuousClock.now.advanced(by: .seconds(10))
            while !spin.isReleased, ContinuousClock.now < stop {}
        }
    }
    defer { spin.release() }
    // Start once a spinner holds every core, or GCD may hand the work an idle thread.
    // The bound keeps a host too busy to start them all from hanging the test.
    let ready = ContinuousClock.now.advanced(by: .seconds(5))
    while spin.startedCount < cores, ContinuousClock.now < ready {
        try await Task.sleep(for: .milliseconds(5))
    }
    return try await body()
}

private final class SpinControl: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var started = 0

    var isReleased: Bool { lock.withLock { released } }

    var startedCount: Int { lock.withLock { started } }

    func markStarted() { lock.withLock { started += 1 } }

    func release() { lock.withLock { released = true } }
}
#endif
