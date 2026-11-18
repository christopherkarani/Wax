import Foundation

/// Runs blocking work, such as a subprocess wait, a pipe read, a synchronous
/// socket round trip or a sleep, on a GCD thread instead of a Swift
/// concurrency cooperative thread.
///
/// The cooperative pool has one thread per core. Work that blocks one of those
/// threads for the life of a child process stalls every other task in the
/// process. This is how a parallel test run starves on a small CI runner.
///
/// The work runs to completion exactly as it would inline: cancelling the
/// awaiting task does not interrupt it, so timeouts, output caps and
/// kill-on-timeout behave as they did before.
///
/// Each call gets its own serial queue. GCD always gives a serial queue's work
/// a thread, while it caps the threads a shared concurrent queue runs at once
/// by the core count, so an item waits until a running one finishes or yields
/// its core. Blocking work is mostly waiting, yet it queued that way: in a
/// parallel test run the work of a 0.1 s CLI call waited about 50 s to start.
///
/// The queues set no QoS, so each work item keeps the QoS of the task that
/// submits it. A demoted item waits behind the caller's peers for a core,
/// which on a loaded host adds seconds to a call the caller is blocked on.
package enum BlockingWork {
    private static func queue() -> DispatchQueue {
        DispatchQueue(label: "com.wax.blocking-work")
    }

    package static func run<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue().async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    package static func run<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue().async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Runs async work whose synchronous stretches never suspend, such as tokenizing a
    /// long text through an actor, on a private serial queue. Under the task executor
    /// preference, the closure's nonisolated code and the default actors it calls run
    /// there instead of on the cooperative pool. Before macOS 15 it runs inline.
    package static func runAsync<T: Sendable>(
        _ work: @Sendable () async -> T
    ) async -> T {
        if #available(macOS 15.0, iOS 18.0, *) {
            return await withTaskExecutorPreference(SerialQueueExecutor(queue: queue())) {
                await work()
            }
        }
        return await work()
    }
}

@available(macOS 15.0, iOS 18.0, *)
private final class SerialQueueExecutor: TaskExecutor {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
