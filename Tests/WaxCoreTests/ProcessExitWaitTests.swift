#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import WaxCore

/// `Process.waitForExit(timeout:)` returns for a child that is already gone,
/// reports its status, and kills one that will not exit instead of waiting on it.
@Suite struct ProcessExitWaitTests {
    @Test func returnsTheStatusOfAChildThatHasAlreadyExited() throws {
        let process = try launch("exit 3")
        try waitUntilReaped(process)
        #expect(process.waitForExit(timeout: 5) == 3)
    }

    @Test func waitsForAChildThatExitsBeforeTheDeadline() throws {
        let process = try launch("sleep 0.2; exit 4")
        #expect(process.waitForExit(timeout: 30) == 4)
    }

    @Test func killsAChildThatWillNotExit() throws {
        // Runs far past the wait, and is reaped once killed.
        let process = try launch("exec sleep 60")
        #expect(process.waitForExit(timeout: 0.2) == nil)
        #expect(!process.isRunning, "the child outlived the wait")
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
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
            try #require(Date() < deadline, "the child was never reaped")
            usleep(10_000)
        }
    }
}
#endif
