#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import WaxCore

/// `Process.waitForExit(timeout:)` returns for a child that is already gone,
/// reports its status, and kills one that will not exit instead of waiting on it.
@Suite struct ProcessExitWaitTests {
    @Test func returnsTheStatusOfAChildThatHasAlreadyExited() async throws {
        let process = try launch("exit 3")
        // Foundation clears isRunning once it has reaped the child.
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.waitForExit(timeout: 5) == 3)
        #expect(await process.waitForExitOffPool(timeout: 5) == 3)
    }

    @Test func waitsForAChildThatExitsBeforeTheDeadline() async throws {
        let blocking = try launch("sleep 0.2; exit 0")
        #expect(blocking.waitForExit(timeout: 30) == 0)

        let offPool = try launch("sleep 0.2; exit 4")
        #expect(await offPool.waitForExitOffPool(timeout: 30) == 4)
    }

    @Test func killsAChildThatWillNotExit() async throws {
        // Runs far past the wait, and is reaped once killed.
        let blocking = try launch("exec sleep 60")
        #expect(blocking.waitForExit(timeout: 0.2) == nil)
        expectKilled(blocking)

        let offPool = try launch("exec sleep 60")
        #expect(await offPool.waitForExitOffPool(timeout: 0.2) == nil)
        expectKilled(offPool)
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

    private func expectKilled(_ process: Process) {
        #expect(!process.isRunning, "the child outlived the wait")
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }
}
#endif
