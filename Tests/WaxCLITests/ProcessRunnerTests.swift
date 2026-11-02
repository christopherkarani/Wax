import Foundation
import Testing
@testable import wax_cli

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test func runCapturedTimeoutThrowsOnSlowCommand() throws {
        let started = Date()
        #expect(throws: CLIError.self) {
            _ = try ProcessRunner.runCaptured(command: "/bin/sleep", arguments: ["30"], timeoutSeconds: 0.2)
        }
        // Must fail fast: well under the sleep duration.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func runCapturedTimeoutAllowsFastCommand() throws {
        let output = try ProcessRunner.runCaptured(command: "/bin/echo", arguments: ["hi"], timeoutSeconds: 5)
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.contains("hi"))
    }

    @Test func runCapturedWithoutTimeoutBehavesAsBefore() throws {
        let output = try ProcessRunner.runCaptured(command: "/bin/echo", arguments: ["ok"])
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.contains("ok"))
    }

    /// 200 KB on stdout, then 200 KB on stderr. Reading the pipes only after
    /// exit deadlocks (each holds ~64 KB); the timeout turns that into a
    /// failure instead of a hang.
    @Test func runCapturedDrainsLargeOutputOnBothStreams() throws {
        let script = """
        head -c 200000 /dev/zero | tr '\\000' o
        head -c 200000 /dev/zero | tr '\\000' e 1>&2
        """
        let output = try ProcessRunner.runCaptured(
            command: "/bin/sh",
            arguments: ["-c", script],
            timeoutSeconds: 20
        )
        #expect(output.status == EXIT_SUCCESS)
        #expect(output.stdout.utf8.count == 200_000)
        #expect(output.stderr.utf8.count == 200_000)
    }
}
