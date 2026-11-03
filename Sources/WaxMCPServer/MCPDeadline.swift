#if MCPServer
import Foundation

/// Waits for a task's value up to a deadline, then stops waiting.
///
/// A task group cannot do this: it waits for every child before returning,
/// and some awaits (a JSON-RPC request the peer never answers) ignore
/// cancellation. The task keeps running after the deadline; only the wait
/// is bounded.
enum MCPDeadline {
    static func value<T: Sendable>(
        of task: Task<T, Never>,
        within deadline: Duration,
        orElse fallback: T
    ) async -> T {
        let gate = Gate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let timer = Task {
                try? await Task.sleep(for: deadline)
                gate.finish(fallback)
            }
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
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: T) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
#endif
