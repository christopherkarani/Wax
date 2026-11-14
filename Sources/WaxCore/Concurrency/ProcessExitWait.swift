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
/// This wait polls `isRunning` instead, which Foundation clears once it has
/// reaped the child. At the deadline it kills the child with SIGKILL and waits a
/// short while for the reap.
extension Process {
    /// How long a killed child gets to be reaped before the wait gives up.
    package static let exitWaitKillReapSeconds: TimeInterval = 5
    private static let exitWaitPollMicroseconds: useconds_t = 10_000

    /// Blocks the calling thread until the child exits or `timeout` passes. Run
    /// it off the cooperative pool when the timeout is long.
    ///
    /// Pass `.infinity` for a child that may rightly run as long as it likes,
    /// such as an interactive command. That still avoids the lost wakeup.
    ///
    /// - Returns: The termination status, or nil when the child was still
    ///   running at the deadline and was killed. After nil the child may still
    ///   be running, so do not read `terminationStatus`.
    @discardableResult
    package func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = timeout.isFinite ? Date().addingTimeInterval(timeout) : .distantFuture
        if pollUntilExited(deadline: deadline) {
            return terminationStatus
        }
        let pid = processIdentifier
        if Self.isUnreapedChild(pid) {
            kill(pid, SIGKILL)
        }
        _ = pollUntilExited(deadline: Date().addingTimeInterval(Self.exitWaitKillReapSeconds))
        return nil
    }

    /// Whether `pid` is still a child of this process that has not been reaped,
    /// checked without reaping it. Foundation reaps the child on its own queue
    /// and clears `isRunning` a moment later. In that gap the pid may already
    /// belong to an unrelated process, which must not be killed. `waitid`
    /// reports ECHILD once the child is reaped. Other failures count as unreaped,
    /// so the child is still killed.
    package static func isUnreapedChild(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return true
            }
            if errno != EINTR {
                return errno != ECHILD
            }
        }
    }

    #if os(Linux)
    /// The child's exit status once the child itself has exited, read without
    /// reaping it; nil while it runs or once it has been reaped.
    ///
    /// swift-corelibs-foundation learns that a child exited when a socket the
    /// child inherited reaches EOF, and only then reaps it and clears
    /// `isRunning`. A background grandchild inherits that socket too, so
    /// `isRunning` stays true (and `terminationStatus` traps) until the
    /// grandchild exits, long after the child has. `waitid` with `WNOWAIT` sees
    /// the child's own exit and leaves the reap to Foundation.
    ///
    /// The status matches `terminationStatus`: the exit code, or the signal
    /// number for a child killed by a signal.
    package func unreapedExitStatus() -> Int32? {
        let pid = processIdentifier
        guard pid > 0 else { return nil }
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            guard errno == EINTR else { return nil }
        }
        // WNOHANG with no exited child leaves si_pid zero.
        guard info._sifields._sigchld.si_pid == pid else { return nil }
        return info._sifields._sigchld.si_status
    }
    #endif

    private func pollUntilExited(deadline: Date) -> Bool {
        while isRunning {
            guard Date() < deadline else { return false }
            usleep(Self.exitWaitPollMicroseconds)
        }
        return true
    }
}
#endif
