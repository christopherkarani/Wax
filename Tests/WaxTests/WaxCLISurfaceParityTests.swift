import Foundation
import Testing

@Test func waxCLIExposesBrokerParityCommands() throws {
    let source = try WaxCLISource.load("WaxCLICommand.swift")

    let requiredCommands = [
        "MemoryAppendCommand.self",
        "MemorySearchCommand.self",
        "MemoryGetCommand.self",
        "MemoryPromoteCommand.self",
        "PromoteCommand.self",
        "MemoryHealthCommand.self",
        "KnowledgeCaptureCommand.self",
        "SessionStartCommand.self",
        "SessionResumeCommand.self",
        "SessionEndCommand.self",
        "SessionSynthesizeCommand.self",
        "CompactContextCommand.self",
        "CorpusSearchCommand.self",
        "MarkdownExportCommand.self",
        "MarkdownSyncCommand.self",
    ]

    for command in requiredCommands {
        #expect(source.contains(command), "Missing CLI broker parity command \(command)")
    }
}

@Test func waxCLIParitySessionLifecycleUsesPersistentBroker() throws {
    let executable = try WaxCLIProcess.builtProductURL()
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wax-cli-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let storePath = tempDir.appendingPathComponent("memory.wax").path
    let sessionID = UUID().uuidString
    let baseArgs = ["--store-path", storePath, "--no-embedder", "--format", "json"]

    let start = try WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["session-start"] + baseArgs + ["--arg", "session_id=\(sessionID)"]
    )
    #expect(start.status == 0, "session-start failed: \(start.stderr)")

    let append = try WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["memory-append"] + baseArgs + ["--arg", "session_id=\(sessionID)", "session lifecycle smoke"]
    )
    #expect(append.status == 0, "memory-append failed: \(append.stderr)")

    let search = try WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["memory-search"] + baseArgs + ["--arg", "session_id=\(sessionID)", "smoke"]
    )
    #expect(search.status == 0, "memory-search failed: \(search.stderr)")
    #expect(search.stdout.contains("session lifecycle"))

    let end = try WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["session-end"] + baseArgs + ["--arg", "session_id=\(sessionID)"]
    )
    #expect(end.status == 0, "session-end failed: \(end.stderr)")
}

@Test func waxCLIParityCommandsRejectDirectStore() throws {
    let executable = try WaxCLIProcess.builtProductURL()
    let output = try WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["memory-health", "--direct-store"]
    )
    #expect(output.status != 0)
    #expect(output.stderr.contains("--direct-store is not supported for broker parity commands"))
}

private enum WaxCLISource {
    static func load(_ relativePath: String, filePath: String = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/WaxCLI")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private enum WaxCLIProcess {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func builtProductURL(filePath: String = #filePath) throws -> URL {
        let packageRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/wax-cli"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wax-cli"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw WaxCLITestError("Build wax-cli before running this test")
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 15
    ) throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            throw WaxCLITestError("Process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private struct WaxCLITestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
