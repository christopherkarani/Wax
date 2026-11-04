// Darwin only: `observe` sets SIGINT to SIG_IGN there before the source
// registers, so raising it in the test process is safe. On Linux libdispatch
// installs its handler asynchronously, and a SIGINT that beat it would kill
// the test process.
#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Testing
@testable import WaxCore

/// Signals that arrive before the handler runs merge into one dispatch event.
/// The handler must still see each of them, or a second SIGTERM sent while the
/// first is waiting for a thread would never force the daemon's exit.
@Suite struct ShutdownSignalsTests {
    @Test(.timeLimit(.minutes(1)))
    func handlerSeesEverySignalEvenWhenTheyArriveTogether() async throws {
        let queue = DispatchQueue(label: "shutdown-signals-test")
        let calls = SignalCalls()
        // `observe` sets SIG_IGN; put back what the test process had (SIG_DFL).
        let previous = ShutdownSignals.watched.map { signalNumber in
            var action = sigaction()
            sigaction(signalNumber, nil, &action)
            return (signalNumber, action)
        }
        let sources = ShutdownSignals.observe(queue: queue) { calls.record($0) }
        defer {
            sources.forEach { $0.cancel() }
            for (signalNumber, action) in previous {
                var action = action
                sigaction(signalNumber, &action, nil)
            }
        }
        // The sources register on their queue; this runs once they have.
        queue.sync {}

        // Busy until both signals are in, so they reach the handler as one event.
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        raise(SIGINT)
        raise(SIGINT)
        // Time for dispatch to take in the second signal before the handler can
        // run. The result does not depend on it: one merged event or two, the
        // handler must be called twice.
        try await Task.sleep(for: .milliseconds(200))
        gate.signal()

        let deadline = Date().addingTimeInterval(30)
        while calls.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.signals == [SIGINT, SIGINT])
    }
}

private final class SignalCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int32] = []

    func record(_ signal: Int32) {
        lock.withLock { received.append(signal) }
    }

    var signals: [Int32] {
        lock.withLock { received }
    }

    var count: Int {
        lock.withLock { received.count }
    }
}
#endif
