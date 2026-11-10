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
    /// Cancelling the calling task cancels `operation` and throws `CancellationError`
    /// right away, without waiting for `operation` to observe the cancellation.
    ///
    /// - Important: The underlying operation may continue running after the timeout fires.
    ///   The deadline is a GCD timer so a blocked cooperative thread (Core ML load,
    ///   `Thread.sleep`) cannot starve the timeout. Durations too large to represent in
    ///   nanoseconds never fire.
    package static func run<T: Sendable>(
        timeout: Duration,
        operation name: StaticString,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = OnceThrowingContinuation<T>()
        let cancels = CancelBox()
        let deadline = DeadlineBox()
        let operationTask = Task { try await operation() }
        // Resume BEFORE cancelling: cancelling first lets a cooperatively cancellable
        // operation complete with CancellationError, and the watcher task (running on
        // another executor thread) can then win the once-only resume race —
        // misclassifying a timeout as a cancellation.
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            guard once.resume(with: result) else { return }
            operationTask.cancel()
            cancels.cancelWatcher()
            deadline.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                // A serial queue of its own, not a global one: GCD always gives a serial
                // queue a thread, while a global queue waits for a free core, and on a
                // busy host a blocked operation could finish before its timeout fired.
                let timer = DispatchSource.makeTimerSource(
                    queue: DispatchQueue(label: "com.wax.async-timeout", qos: .userInitiated)
                )
                timer.schedule(deadline: dispatchDeadline(after: timeout))
                timer.setEventHandler {
                    finish(.failure(TimeoutError(operation: String(describing: name), timeout: timeout)))
                }
                deadline.install(timer)
                timer.resume()

                cancels.setWatcher(Task {
                    finish(await operationTask.result)
                })
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Converts `duration` to a dispatch deadline without overflowing: negative durations
    /// fire immediately and durations past `Int64` nanoseconds never fire.
    static func dispatchDeadline(after duration: Duration) -> DispatchTime {
        let components = duration.components
        guard components.seconds >= 0 else { return .now() }
        let scaled = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !scaled.overflow else { return .distantFuture }
        let total = scaled.partialValue.addingReportingOverflow(components.attoseconds / 1_000_000_000)
        guard !total.overflow else { return .distantFuture }
        return .now() + .nanoseconds(Int(clamping: total.partialValue))
    }
}

private final class DeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var isCancelled = false

    /// Holds `source` for a later `cancel()`; cancels it at once if that already ran.
    func install(_ source: DispatchSourceTimer) {
        let alreadyCancelled = lock.withLock {
            if isCancelled { return true }
            timer = source
            return false
        }
        if alreadyCancelled {
            source.cancel()
        }
    }

    func cancel() {
        let source: DispatchSourceTimer? = lock.withLock {
            isCancelled = true
            let installed = timer
            timer = nil
            return installed
        }
        source?.cancel()
    }
}

// MARK: - OnceThrowingContinuation

private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var watcher: Task<Void, Never>?

    func setWatcher(_ task: Task<Void, Never>) {
        lock.withLock { watcher = task }
    }

    func cancelWatcher() {
        lock.withLock { watcher }?.cancel()
    }
}

/// Resumes a continuation exactly once. A result that arrives before the continuation
/// is installed (for example cancellation of an already-cancelled caller) is held and
/// delivered on `install`.
private final class OnceThrowingContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, any Error>?
    private var isResolved = false

    private enum ResumeAction {
        case alreadyResolved
        case held
        case resume(CheckedContinuation<T, Error>)
    }

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let pending: Result<T, any Error>? = lock.withLock {
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(with: pending)
        }
    }

    /// Returns `false` when a result was already delivered.
    @discardableResult
    func resume(with result: Result<T, any Error>) -> Bool {
        let action: ResumeAction = lock.withLock {
            guard !isResolved else { return .alreadyResolved }
            isResolved = true
            guard let continuation else {
                pendingResult = result
                return .held
            }
            self.continuation = nil
            return .resume(continuation)
        }
        switch action {
        case .alreadyResolved:
            return false
        case .held:
            return true
        case .resume(let continuation):
            continuation.resume(with: result)
            return true
        }
    }
}
