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
/// for at most `limit`. The pool's width differs by host and mode (one thread per core,
/// one under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), so the hold reads it from the
/// runtime: it adds holders one at a time until one cannot start.
@available(macOS 15.0, iOS 18.0, *)
private final class CooperativePoolHold: @unchecked Sendable {
    static let limit: DispatchTimeInterval = .seconds(20)
    /// How long a new holder may wait for a thread before the pool counts as held.
    /// Too short only leaves a thread free (a weaker test), never a false failure.
    private static let probeWait: DispatchTimeInterval = .milliseconds(500)
    private static let maxHolders = 256

    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var spawned = 0
    private var released = false
    private var gaveUp = false

    /// Returns true once holders block every cooperative thread, or false when none
    /// could start within `limit` or the pool never filled within `maxHolders`. Call
    /// it off the pool: it blocks while it waits.
    func engage() -> Bool {
        // The first holder may queue behind the suite's other jobs.
        guard addHolder(waitingUpTo: Self.limit) else { return false }
        for _ in 1..<Self.maxHolders where !addHolder(waitingUpTo: Self.probeWait) {
            // This holder found no free thread. It stays queued and takes the next
            // thread that frees, so the pool stays held.
            return true
        }
        return false
    }

    /// Ends the hold. True when no holder gave up first.
    func release() -> Bool {
        let holders = lock.withLock { () -> Int in
            released = true
            return spawned
        }
        for _ in 0..<holders {
            gate.signal()
        }
        return lock.withLock { !gaveUp }
    }

    private func addHolder(waitingUpTo wait: DispatchTimeInterval) -> Bool {
        lock.withLock { spawned += 1 }
        Task(executorPreference: globalConcurrentExecutor) { self.block() }
        return started.wait(timeout: .now() + wait) == .success
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
