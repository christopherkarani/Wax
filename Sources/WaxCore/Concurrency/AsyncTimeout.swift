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
    /// The timeout counts from when `operation` starts running. Time its task spends
    /// waiting for a thread in a busy process is not the operation's: the caller could
    /// not resume any sooner, and a deadline armed at the call fails an instant
    /// operation that merely queued behind other work.
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
        try await run(timeout: timeout, operation: name, startingWith: { body in Task { await body() } }, operation)
    }

    /// `launch` starts the operation's task around `body`. Tests pass one that delays the
    /// start, standing in for that task waiting for a thread; product code always uses
    /// a plain `Task`.
    static func run<T: Sendable>(
        timeout: Duration,
        operation name: StaticString,
        startingWith launch: (@escaping @Sendable () async -> Void) -> Task<Void, Never>,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = OnceThrowingContinuation<T>()
        let operationTask = CancelBox()
        let deadline = DeadlineBox()
        // Resume BEFORE cancelling: cancelling first lets a cooperatively cancellable
        // operation complete with CancellationError and win the once-only resume race,
        // misclassifying a timeout as a cancellation.
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            guard once.resume(with: result) else { return }
            operationTask.cancel()
            deadline.cancel()
        }

        operationTask.set(launch {
            // Armed first, before any await or actor hop: an operation that starts and
            // then waits on a busy actor or a lost continuation is still bounded.
            // A serial queue of its own, not a global one: GCD always gives a serial
            // queue a thread, while it caps a global queue's threads by the core count,
            // and on a busy host a blocked operation could finish before its timeout fired.
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "com.wax.async-timeout", qos: .userInitiated)
            )
            timer.schedule(deadline: dispatchDeadline(after: timeout))
            timer.setEventHandler {
                finish(.failure(TimeoutError(operation: String(describing: name), timeout: timeout)))
            }
            deadline.install(timer)
            timer.resume()
            // The result is delivered from this task: a separate watcher task would wait
            // for a thread of its own before the caller could resume.
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        })

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Converts `duration` to a dispatch deadline without overflowing: negative durations
    /// fire immediately and durations past `Int64` nanoseconds never fire.
    package static func dispatchDeadline(after duration: Duration) -> DispatchTime {
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

/// Holds the operation's task for a later `cancel()`; cancels it at once if that already ran.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func set(_ newTask: Task<Void, Never>) {
        let alreadyCancelled = lock.withLock {
            if isCancelled { return true }
            task = newTask
            return false
        }
        if alreadyCancelled {
            newTask.cancel()
        }
    }

    func cancel() {
        let installed: Task<Void, Never>? = lock.withLock {
            isCancelled = true
            let installed = task
            task = nil
            return installed
        }
        installed?.cancel()
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
