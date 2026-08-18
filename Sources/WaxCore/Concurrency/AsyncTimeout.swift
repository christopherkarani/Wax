import Foundation

/// Runs an async operation with a timeout without relying on cooperative cancellation.
///
/// This is intentionally implemented using unstructured tasks so that the caller can
/// return when the timeout elapses even if the underlying operation does not observe
/// cancellation (common with some I/O and CoreML paths).
package enum AsyncTimeout {
    package struct TimeoutError: Error, LocalizedError, Sendable, Equatable {
        package let operation: String
        package let timeout: Duration

        package init(operation: String, timeout: Duration) {
            self.operation = operation
            self.timeout = timeout
        }

        package var errorDescription: String? {
            "Timed out after \(timeout) during \(operation)"
        }
    }

    /// Execute `operation` and throw `TimeoutError` if it does not finish within `timeout`.
    ///
    /// - Important: The underlying operation may continue running after the timeout fires.
    ///   The deadline is a GCD timer so a blocked cooperative thread (Core ML load,
    ///   `Thread.sleep`) cannot starve the timeout.
    package static func run<T: Sendable>(
        timeout: Duration,
        operation name: StaticString,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceThrowingContinuation<T>(continuation)
            let cancels = CancelBox()
            let operationTask = Task { try await operation() }
            let deadline = DeadlineBox()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            deadline.timer = timer
            timer.schedule(deadline: .now() + dispatchInterval(timeout))
            timer.setEventHandler {
                // Resume BEFORE cancelling: cancelling first lets a cooperatively
                // cancellable operation complete with CancellationError, and the
                // watcher task (running on another executor thread) can then win the
                // once-only resume race — misclassifying a timeout as a cancellation.
                _ = once.resume(throwing: TimeoutError(operation: String(describing: name), timeout: timeout))
                operationTask.cancel()
                cancels.cancelWatcher()
                deadline.cancel()
            }
            timer.resume()

            let watcherTask = Task {
                let result = await operationTask.result
                switch result {
                case .success(let value):
                    if once.resume(returning: value) { deadline.cancel() }
                case .failure(let error):
                    if once.resume(throwing: error) { deadline.cancel() }
                }
            }
            cancels.setWatcher(watcherTask)
        }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return .nanoseconds(Int(clamping: nanoseconds))
    }
}

private final class DeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    var timer: DispatchSourceTimer?

    func cancel() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }
}

// MARK: - OnceThrowingContinuation

private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var watcher: Task<Void, Never>?

    func setWatcher(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        watcher = task
    }

    func cancelWatcher() {
        lock.lock()
        let task = watcher
        lock.unlock()
        task?.cancel()
    }
}

private final class OnceThrowingContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let cont = continuation else { return false }
        continuation = nil
        cont.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: any Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let cont = continuation else { return false }
        continuation = nil
        cont.resume(throwing: error)
        return true
    }
}
