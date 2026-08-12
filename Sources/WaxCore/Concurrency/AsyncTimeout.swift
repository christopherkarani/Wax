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
    /// Caller cancellation resumes with `CancellationError` immediately and cancels the
    /// operation, timeout, and watcher tasks exactly once. An operation that ignores
    /// cooperative cancellation is left to finish off-path as unstructured work.
    ///
    /// - Important: The underlying operation may continue running after the timeout fires
    ///   or the caller is cancelled.
    package static func run<T: Sendable>(
        timeout: Duration,
        operation name: StaticString,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let session = TimeoutRunSession<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = OnceThrowingContinuation<T>(continuation)
                guard session.bind(once) else {
                    _ = once.resume(throwing: CancellationError())
                    return
                }

                let operationTask = Task<T, Error> {
                    try await operation()
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    // Resume BEFORE cancelling: cancelling first lets a cooperatively
                    // cancellable operation complete with CancellationError, and the
                    // watcher task (running on another executor thread) can then win the
                    // once-only resume race — misclassifying a timeout as a cancellation.
                    _ = once.resume(
                        throwing: TimeoutError(operation: String(describing: name), timeout: timeout)
                    )
                    operationTask.cancel()
                    session.cancelWatcher()
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
                session.install(
                    operation: operationTask,
                    timeout: timeoutTask,
                    watcher: watcherTask
                )
            }
        } onCancel: {
            session.cancelFromCaller()
        }
    }
}

// MARK: - TimeoutRunSession

/// Coordinates once-only resume with caller-cancellation ownership of the three
/// unstructured tasks. `AsyncMutex` is not used: this is a tiny non-async critical
/// section (bind/install/cancel), not a FIFO async lock.
private final class TimeoutRunSession<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var once: OnceThrowingContinuation<T>?
    private var operationTask: Task<T, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var callerCancelled = false

    /// Returns `false` if the caller already cancelled, so the continuation can
    /// resume immediately without starting child work.
    func bind(_ once: OnceThrowingContinuation<T>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if callerCancelled { return false }
        self.once = once
        return true
    }

    func install(
        operation: Task<T, Error>,
        timeout: Task<Void, Never>,
        watcher: Task<Void, Never>
    ) {
        lock.lock()
        let alreadyCancelled = callerCancelled
        if !alreadyCancelled {
            operationTask = operation
            timeoutTask = timeout
            watcherTask = watcher
        }
        lock.unlock()
        if alreadyCancelled {
            operation.cancel()
            timeout.cancel()
            watcher.cancel()
        }
    }

    func cancelFromCaller() {
        lock.lock()
        callerCancelled = true
        let once = self.once
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        let watcherTask = self.watcherTask
        lock.unlock()

        _ = once?.resume(throwing: CancellationError())
        operationTask?.cancel()
        timeoutTask?.cancel()
        watcherTask?.cancel()
    }

    func cancelWatcher() {
        lock.lock()
        let watcher = watcherTask
        lock.unlock()
        watcher?.cancel()
    }
}

// MARK: - OnceThrowingContinuation

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
