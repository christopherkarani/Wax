import Foundation
import Testing
@testable import Wax
@testable import wax_cli
import WaxCore

@Test func waxCLIVersionComesFromReleaseInfo() {
    #expect(WaxCLI.configuration.version == WaxReleaseInfo.version)
}

/// `runCaptured` blocks its thread until the child exits, for up to the timeout. Called
/// inline from a test it held a cooperative thread that long, and on a 3-core CI runner that
/// starved the rest of the parallel run, so these calls run on a GCD thread.
private func runCaptured(
    command: String,
    arguments: [String],
    timeoutSeconds: TimeInterval? = nil
) async throws -> CapturedProcessOutput {
    try await BlockingWork.run {
        try ProcessRunner.runCaptured(command: command, arguments: arguments, timeoutSeconds: timeoutSeconds)
    }
}

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test func runCapturedTimeoutThrowsOnSlowCommand() async throws {
        let started = Date()
        await #expect(throws: CLIError.self) {
            _ = try await runCaptured(command: "/bin/sleep", arguments: ["30"], timeoutSeconds: 0.2)
        }
        // Must fail fast: well under the sleep duration.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func runCapturedTimeoutAllowsFastCommand() async throws {
        let output = try await runCaptured(command: "/bin/echo", arguments: ["hi"], timeoutSeconds: 5)
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.contains("hi"))
    }

    @Test func runCapturedWithoutTimeoutBehavesAsBefore() async throws {
        let output = try await runCaptured(command: "/bin/echo", arguments: ["ok"])
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.contains("ok"))
    }

    /// 200 KB on stdout, then 200 KB on stderr. Reading the pipes only after
    /// exit deadlocks (each holds ~64 KB); the timeout turns that into a
    /// failure instead of a hang.
    @Test func runCapturedDrainsLargeOutputOnBothStreams() async throws {
        let script = """
        head -c 200000 /dev/zero | tr '\\000' o
        head -c 200000 /dev/zero | tr '\\000' e 1>&2
        """
        let output = try await runCaptured(
            command: "/bin/sh",
            arguments: ["-c", script],
            timeoutSeconds: 20
        )
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.utf8.count == 200_000)
        #expect(output.stderr.utf8.count == 200_000)
    }

    @Test func runCapturedTimeoutKillsAChildThatIgnoresSIGTERM() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-runner-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // `exec` keeps one process; the ignored TERM disposition survives it.
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; exec sleep 30"

        await #expect(throws: CLIError.self) {
            _ = try await runCaptured(command: "/bin/sh", arguments: ["-c", script], timeoutSeconds: 0.5)
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "child \(pid) outlived the timeout")
    }

    @Test func runCapturedReturnsWhenABackgroundChildHoldsThePipes() async throws {
        let started = Date()
        let output = try await runCaptured(
            command: "/bin/sh",
            arguments: ["-c", "sleep 20 & echo done"],
            timeoutSeconds: 2
        )
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(output.stdout.contains("done"))
    }

    @Test func runCapturedCapsCapturedOutput() async throws {
        let cap = ProcessRunner.maxCapturedBytesPerStream
        let output = try await runCaptured(
            command: "/bin/sh",
            arguments: ["-c", "head -c \(cap + 1_000_000) /dev/zero | tr '\\000' o"],
            timeoutSeconds: 30
        )
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.utf8.count < cap + 1_024)
        #expect(output.stdout.hasSuffix(ProcessRunner.truncationMarker(limit: cap)))
    }
}
