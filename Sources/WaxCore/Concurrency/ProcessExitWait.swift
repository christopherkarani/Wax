#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bounded waits for a child `Process` that do not use a run loop.
///
/// `waitUntilExit()` runs the calling thread's run loop until Foundation reports
/// the termination. Under heavy load that wakeup can be lost. The child has
/// exited and been reaped, and `isRunning` is false, yet the caller stays parked
/// in the run loop for good. A test hung like that for almost 11 hours. The wait
/// also holds its thread, so on the cooperative pool it holds up every other task.
///
/// These waits poll `isRunning` instead, which Foundation clears once it has
/// reaped the child. At the deadline they kill the child with SIGKILL and wait a
/// short while for the reap.
extension Process {
    /// How long a killed child gets to be reaped before the wait gives up.
    package static let exitWaitKillReapSeconds: TimeInterval = 5
    private static let exitWaitPollMicroseconds: useconds_t = 10_000

    /// Blocks the calling thread until the child exits or `timeout` passes. On
    /// the cooperative pool, prefer `waitForExitOffPool(timeout:)`.
    ///
    /// Pass `.infinity` for a child that may rightly run as long as it likes,
    /// such as an interactive command. That still avoids the lost wakeup.
    ///
    /// - Returns: The termination status, or nil when the child was still
    ///   running at the deadline and was killed.
    @discardableResult
    package func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = timeout.isFinite ? Date().addingTimeInterval(timeout) : .distantFuture
        if pollUntilExited(deadline: deadline) {
            return terminationStatus
        }
        kill(processIdentifier, SIGKILL)
        _ = pollUntilExited(deadline: Date().addingTimeInterval(Self.exitWaitKillReapSeconds))
        return nil
    }

    /// `waitForExit(timeout:)` on a GCD thread, so no cooperative thread is held.
    @discardableResult
    package func waitForExitOffPool(timeout: TimeInterval) async -> Int32? {
        let process = UncheckedProcess(process: self)
        return await BlockingWork.run { process.process.waitForExit(timeout: timeout) }
    }

    private func pollUntilExited(deadline: Date) -> Bool {
        while isRunning {
            guard Date() < deadline else { return false }
            usleep(Self.exitWaitPollMicroseconds)
        }
        return true
    }
}

/// `Process` is not `Sendable` on every platform. The wait only reads
/// `isRunning` and the termination status, which Foundation guards.
private struct UncheckedProcess: @unchecked Sendable {
    let process: Process
}
#endif
