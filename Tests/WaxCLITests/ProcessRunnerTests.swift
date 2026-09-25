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
}
