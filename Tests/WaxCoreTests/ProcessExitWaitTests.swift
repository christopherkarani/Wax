#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import WaxCore

/// `Process.waitForExit(timeout:)` returns for a child that is already gone,
/// reports its status, and kills one that will not exit instead of waiting on it.
@Suite struct ProcessExitWaitTests {
    private struct NeverReaped: Error, CustomStringConvertible {
        var description: String { "the child was never reaped" }
    }

    // The waits poll with usleep, so they run on a GCD thread, not a cooperative one.

    @Test func returnsTheStatusOfAChildThatHasAlreadyExited() async throws {
        let status = try await BlockingWork.run { () throws -> Int32? in
            let process = try launch("exit 3")
            try waitUntilReaped(process)
            return process.waitForExit(timeout: 5)
        }
        #expect(status == 3)
    }

    @Test func waitsForAChildThatExitsBeforeTheDeadline() async throws {
        let status = try await BlockingWork.run { () throws -> Int32? in
            try launch("sleep 0.2; exit 4").waitForExit(timeout: 30)
        }
        #expect(status == 4)
    }

    @Test func killsAChildThatWillNotExit() async throws {
        // Runs far past the wait, and is reaped once killed.
        let (status, isRunning, diedOfSignal, terminationStatus) = try await BlockingWork.run {
            () throws -> (Int32?, Bool, Bool, Int32) in
            let process = try launch("exec sleep 60")
            let status = process.waitForExit(timeout: 0.2)
            return (
                status,
                process.isRunning,
                process.terminationReason == .uncaughtSignal,
                process.terminationStatus
            )
        }
        #expect(status == nil)
        #expect(!isRunning, "the child outlived the wait")
        #expect(diedOfSignal)
        #expect(terminationStatus == SIGKILL)
    }

    /// The kill at the deadline is skipped once Foundation has reaped the
    /// child, because its pid may then belong to another process.
    @Test func onlyAnUnreapedChildCountsAsKillable() throws {
        let running = try launch("exec sleep 60")
        defer { running.waitForExit(timeout: 0) }
        #expect(Process.isUnreapedChild(running.processIdentifier))

        let reaped = try launch("exit 0")
        try waitUntilReaped(reaped)
        #expect(!Process.isUnreapedChild(reaped.processIdentifier))

        // Not a child of this process at all.
        #expect(!Process.isUnreapedChild(1))
    }

    private func launch(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Foundation clears isRunning once it has reaped the child.
    private func waitUntilReaped(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            guard Date() < deadline else { throw NeverReaped() }
            usleep(10_000)
        }
    }
}
#endif
