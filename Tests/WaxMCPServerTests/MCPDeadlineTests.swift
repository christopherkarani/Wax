#if MCPServer
import Foundation
import Testing
@testable import wax_mcp

/// The deadline must fire while every cooperative thread is busy, as in a loaded
/// shutdown. The caller waits on a dispatch-queue task executor, so it needs no pool
/// thread, and the pool is released only after the wait returns: a deadline that needs
/// a pool thread to fire cannot return in time. The hold gives up after
/// `CooperativePoolHold.limit` so such a deadline fails the test instead of wedging the
/// process.
@available(macOS 15.0, iOS 18.0, *)
@Test(.timeLimit(.minutes(5)))
func deadlineFiresWhileTheCooperativePoolIsHeld() async {
    let pending = PendingValue()
    let task = Task { await pending.value() }
    let hold = CooperativePoolHold()

    let outcome = await withTaskExecutorPreference(QueueTaskExecutor()) {
        () -> (engaged: Bool, value: String, heldThroughout: Bool) in
        let engaged = hold.engage()
        let value = await MCPDeadline.value(of: task, within: .milliseconds(50), orElse: "deadline")
        return (engaged, value, hold.release())
    }
    pending.finish("value")

    #expect(outcome.engaged, "the pool hold never blocked every cooperative thread")
    #expect(outcome.value == "deadline")
    #expect(outcome.heldThroughout, "the deadline fired only after the pool hold gave up")
}

/// Blocks every cooperative thread at the caller's priority until `release()`, or
/// for at most `limit`.
@available(macOS 15.0, iOS 18.0, *)
private final class CooperativePoolHold: @unchecked Sendable {
    static let limit: DispatchTimeInterval = .seconds(20)

    /// The pool runs one thread per core for each priority, and one under
    /// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (measured on macOS).
    private let width = ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1"
        ? 1
        : ProcessInfo.processInfo.activeProcessorCount
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    private var gaveUp = false

    /// Returns true once a holder blocks every cooperative thread, or false if that
    /// takes longer than `limit`. Call it off the pool: it blocks while it waits.
    func engage() -> Bool {
        for _ in 0..<width {
            Task(executorPreference: globalConcurrentExecutor) { self.block() }
        }
        for _ in 0..<width where started.wait(timeout: .now() + Self.limit) == .timedOut {
            return false
        }
        return true
    }

    /// Ends the hold. True when no holder gave up first.
    func release() -> Bool {
        lock.withLock { released = true }
        for _ in 0..<width {
            gate.signal()
        }
        return lock.withLock { !gaveUp }
    }

    private func block() {
        // A holder that only gets a thread after the release must not hold it.
        guard !lock.withLock({ released }) else { return }
        started.signal()
        if gate.wait(timeout: .now() + Self.limit) == .timedOut {
            lock.withLock { gaveUp = true }
        }
    }
}

/// Runs its jobs on a private serial queue instead of the cooperative pool.
@available(macOS 15.0, iOS 18.0, *)
private final class QueueTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "com.wax.test.deadline-caller")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// A value that arrives when the test calls `finish(_:)`.
private final class PendingValue: @unchecked Sendable {
    private let lock = NSLock()
    private var result: String?
    private var waiter: CheckedContinuation<String, Never>?

    func value() async -> String {
        await withCheckedContinuation { continuation in
            let ready: String? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish(_ value: String) {
        let pending: CheckedContinuation<String, Never>? = lock.withLock {
            result = value
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: value)
    }
}
#endif
