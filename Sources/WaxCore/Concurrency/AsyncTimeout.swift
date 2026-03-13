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
    package static func run<T: Sendable>(
        timeout: Duration,
        operation name: StaticString,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceThrowingContinuation<T>(continuation)
            let cancels = CancelBox()
            let operationTask = Task { try await operation() }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                operationTask.cancel()
                _ = once.resume(throwing: TimeoutError(operation: String(describing: name), timeout: timeout))
                cancels.cancelWatcher()
            }

            let watcherTask = Task {
                let result = await operationTask.result
                switch result {
                case .success(let value):
                    if once.resume(returning: value) { timeoutTask.cancel() }
                case .failure(let error):
                    if once.resume(throwing: error) { timeoutTask.cancel() }
                }
            }
            cancels.setWatcher(watcherTask)
        }
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
