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
/// The queue sets no QoS, so each work item keeps the QoS of the task that
/// submits it. A demoted item waits behind the caller's peers for a core,
/// which on a loaded host adds seconds to a call the caller is blocked on.
package enum BlockingWork {
    private static let queue = DispatchQueue(
        label: "com.wax.blocking-work",
        attributes: .concurrent
    )

    package static func run<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    package static func run<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
