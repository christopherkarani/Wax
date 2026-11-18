import ArgumentParser
import Dispatch
import Foundation
import Wax
import WaxCore

struct CapturedProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Per-stream cap on captured output. Bytes past it are read and
    /// discarded, so the child never blocks on a full pipe.
    static let maxCapturedBytesPerStream = 4 * 1024 * 1024

    static func truncationMarker(limit: Int) -> String {
        "\n[wax-cli: output truncated after \(limit) bytes]\n"
    }

    @discardableResult
    static func run(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        passthrough: Bool = false,
        allowNonZeroExit: Bool = false
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment

        if passthrough {
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }

        try process.run()
        // An interactive command or a build runs as long as it needs. No
        // deadline, but no run loop either: see `Process.waitForExit(timeout:)`.
        process.waitForExit(timeout: .infinity)

        let status = process.terminationStatus
        if !allowNonZeroExit, status != EXIT_SUCCESS {
            throw ExitCode(status)
        }
        return status
    }

    static func runCaptured(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        input: String? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) throws -> CapturedProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        try process.run()
        let drain = ProcessPipeDrain(
            stdout: stdoutPipe,
            stderr: stderrPipe,
            maxBytesPerStream: maxCapturedBytesPerStream
        )

        if let input, let stdinPipe {
            if let data = input.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        let captured: ProcessPipeDrain.Output
        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                stop(process)
                // Release the readers even if a grandchild still holds a pipe.
                _ = drain.wait(until: .now() + pipeDrainGraceSeconds)
                throw CLIError("'\(command)' timed out after \(timeoutSeconds) seconds")
            }
            // The child exited; a background grandchild may still hold the pipes.
            let remaining = max(0, deadline.timeIntervalSinceNow) + pipeDrainGraceSeconds
            captured = drain.wait(until: .now() + remaining)
        } else {
            process.waitForExit(timeout: .infinity)
            captured = drain.wait()
        }

        return CapturedProcessOutput(
            status: process.terminationStatus,
            stdout: decodeCaptured(captured.stdout, truncated: captured.stdoutTruncated),
            stderr: decodeCaptured(captured.stderr, truncated: captured.stderrTruncated)
        )
    }

    private static let terminateGraceSeconds: TimeInterval = 2
    private static let pipeDrainGraceSeconds: TimeInterval = 1

    /// SIGTERM, a grace period, then SIGKILL, so a child that ignores
    /// SIGTERM cannot outlive the timeout. Waits a bounded time for the reap.
    private static func stop(_ process: Process) {
        process.terminate()
        process.waitForExit(timeout: terminateGraceSeconds)
    }

    private static func decodeCaptured(_ data: Data, truncated: Bool) -> String {
        guard truncated else { return String(data: data, encoding: .utf8) ?? "" }
        // The cut can split a UTF-8 sequence; decode what arrived.
        return String(decoding: data, as: UTF8.self) + truncationMarker(limit: maxCapturedBytesPerStream)
    }
}
