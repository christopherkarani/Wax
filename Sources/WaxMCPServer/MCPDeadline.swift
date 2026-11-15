#if MCPServer
import Foundation
import WaxCore

/// Waits for a task's value up to a deadline, then stops waiting.
///
/// A task group cannot do this: it waits for every child before returning,
/// and some awaits (a JSON-RPC request the peer never answers) ignore
/// cancellation. The task keeps running after the deadline; only the wait
/// is bounded.
///
/// The deadline counts from the call. A GCD timer armed here resumes the
/// caller; a timer task would count from whenever a cooperative thread picked
/// it up, which on a busy pool is seconds late.
enum MCPDeadline {
    private static let timerQueue = DispatchQueue(label: "com.wax.mcp-deadline", qos: .userInitiated)

    static func value<T: Sendable>(
        of task: Task<T, Never>,
        within deadline: Duration,
        orElse fallback: T
    ) async -> T {
        let gate = Gate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: AsyncTimeout.dispatchDeadline(after: deadline))
            timer.setEventHandler {
                gate.finish(fallback)
                timer.cancel()
            }
            timer.resume()
            Task {
                let value = await task.value
                timer.cancel()
                gate.finish(value)
            }
        }
    }

    /// Resumes its continuation exactly once, with whichever value arrives first.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func install(_ continuation: CheckedContinuation<T, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func finish(_ value: T) {
            let pending: CheckedContinuation<T, Never>? = lock.withLock {
                let installed = continuation
                continuation = nil
                return installed
            }
            pending?.resume(returning: value)
        }
    }
}
#endif
