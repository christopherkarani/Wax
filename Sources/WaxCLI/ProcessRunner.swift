import Dispatch
import Foundation

struct CapturedProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct MCPSmokeCheckOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    let foundExpectedTool: Bool
    let timedOut: Bool
}

func smokeCheckFailureContext(_ output: MCPSmokeCheckOutput) -> String {
    let stderr = output.stderr
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    if let stderr {
        return "server stderr: \(stderr)"
    }

    let stdout = output.stdout
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    if let stdout {
        return "server stdout: \(stdout)"
    }

    return "No server output captured."
}

enum ProcessRunner {
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
        // nil inherits the parent process environment; pass an explicit dict to isolate.
        process.environment = environment

        if passthrough {
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }

        try process.run()
        process.waitUntilExit()

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
        input: String? = nil
    ) throws -> CapturedProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment

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

        if let input, let stdinPipe {
            if let data = input.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CapturedProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func runMCPSmokeCheck(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        input: String,
        expectedToolName: String,
        timeoutSeconds: TimeInterval = 5
    ) throws -> MCPSmokeCheckOutput {
        final class SmokeCheckState: @unchecked Sendable {
            private let lock = NSLock()
            private var stdoutAll = Data()
            private var stderrAll = Data()
            private var stdoutPending = Data()
            private var toolsListResponse: String?
            private var foundExpectedTool = false
            private var signaled = false
            fileprivate let semaphore = DispatchSemaphore(value: 0)

            func signalOnce() {
                lock.lock()
                defer { lock.unlock() }
                guard !signaled else { return }
                signaled = true
                semaphore.signal()
            }

            func appendStdout(_ data: Data, expectedToolName: String) {
                lock.lock()
                stdoutAll.append(data)
                stdoutPending.append(data)

                while let newlineIndex = stdoutPending.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = stdoutPending[..<newlineIndex]
                    stdoutPending = stdoutPending[(newlineIndex + 1)...]
                    guard !lineData.isEmpty else { continue }
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }

                    if toolsListResponse == nil,
                       (line.contains(#""id":2"#) || line.contains(#""id": 2"#))
                    {
                        toolsListResponse = line
                        foundExpectedTool = line.contains(#""name":"\#(expectedToolName)""#)
                        lock.unlock()
                        signalOnce()
                        return
                    }
                }

                lock.unlock()
            }

            func appendStderr(_ data: Data) {
                lock.lock()
                stderrAll.append(data)
                lock.unlock()
            }

            func snapshot() -> (stdout: Data, stderr: Data, toolsListResponse: String?, foundExpectedTool: Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (stdoutAll, stderrAll, toolsListResponse, foundExpectedTool)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let state = SmokeCheckState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                state.signalOnce()
                return
            }
            state.appendStdout(data, expectedToolName: expectedToolName)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            state.appendStderr(data)
        }

        try process.run()

        if let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }

        let waitResult = state.semaphore.wait(timeout: .now() + timeoutSeconds)
        let timedOut = waitResult == .timedOut

        // Close stdin to request graceful shutdown; also stop active readers.
        try? stdinPipe.fileHandleForWriting.close()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Wait for clean exit.
        process.waitUntilExit()

        // Drain any remaining output.
        if let data = try? stdoutPipe.fileHandleForReading.readToEnd() {
            state.appendStdout(data, expectedToolName: expectedToolName)
        }
        if let data = try? stderrPipe.fileHandleForReading.readToEnd() {
            state.appendStderr(data)
        }

        let snapshot = state.snapshot()
        let stdout = String(data: snapshot.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: snapshot.stderr, encoding: .utf8) ?? ""

        var foundExpectedTool = snapshot.foundExpectedTool
        if snapshot.toolsListResponse == nil {
            foundExpectedTool = stdout.contains(#""name":"\#(expectedToolName)""#)
        }

        return MCPSmokeCheckOutput(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            foundExpectedTool: foundExpectedTool,
            timedOut: timedOut
        )
    }
}
