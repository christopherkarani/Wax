import Foundation
import Testing
import WaxCore

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
        "CompactStoreCommand.self",
        "MemoryMaintainCommand.self",
        "EmbedBackfillCommand.self",
    ]

    for command in requiredCommands {
        #expect(source.contains(command), "Missing CLI broker parity command \(command)")
    }

    for command in ["CompactStoreCommand.self", "EmbedBackfillCommand.self"] {
        let registrations = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) == "\(command)," }
        #expect(
            registrations.count == 1,
            "CLI must register \(command) exactly once, found \(registrations.count)"
        )
    }
}

@Test func waxCLIExposesLinuxDemoCommand() throws {
    let source = try WaxCLISource.load("WaxCLICommand.swift")
    #expect(source.contains("DemoCommand.self"))
}

@Test func waxCLIExposesEmbedBackfillCommand() throws {
    let source = try WaxCLISource.load("WaxCLICommand.swift")
    #expect(source.contains("EmbedBackfillCommand.self"))
}

/// The time limit only catches a hang.
@Test(.timeLimit(.minutes(2)))
func waxCLIParitySessionLifecycleUsesPersistentBroker() async throws {
    try await runParitySessionLifecycle()
}

/// The broker daemon must answer when its cooperative pool is narrow, as on a
/// small or starved runner. Its socket accept loop once blocked in `poll` on a
/// cooperative thread, so on a one-thread pool no client was ever served and
/// `session-start` timed out. The strict pool is a Darwin libdispatch setting;
/// the wax-cli client and the daemon it launches both inherit it.
@Test(.timeLimit(.minutes(2)))
func waxCLIParitySessionLifecycleAnswersOnAStrictCooperativePool() async throws {
    try await runParitySessionLifecycle(extraEnvironment: ["LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"])
}

private func runParitySessionLifecycle(extraEnvironment: [String: String] = [:]) async throws {
    let executable = try WaxCLIProcess.builtProductURL()
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wax-cli-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let storePath = tempDir.appendingPathComponent("memory.wax").path
    let brokerDir = tempDir.appendingPathComponent("broker", isDirectory: true)
    try FileManager.default.createDirectory(at: brokerDir, withIntermediateDirectories: true)
    let sessionID = UUID().uuidString
    let baseArgs = ["--store-path", storePath, "--no-embedder", "--format", "json"]
    let brokerEnv = [
        "WAX_BROKER_DIR": brokerDir.path,
        "WAX_LOCK_TIMEOUT_SECS": "10",
    ].merging(extraEnvironment) { _, extra in extra }

    do {
        try await runParityLifecycleSteps(
            executable: executable,
            baseArgs: baseArgs,
            sessionID: sessionID,
            brokerEnv: brokerEnv
        )
    } catch {
        for broker in (try? await PersistentBroker.find(storeDirectory: tempDir)) ?? [] {
            try? await broker.stopAndConfirmGone()
        }
        throw error
    }

    // The broker outlives each CLI call by design. Stop it so it does not linger
    // for its idle timeout, and check that it is really gone.
    let brokers = try await PersistentBroker.find(storeDirectory: tempDir)
    #expect(brokers.count == 1, "expected one persistent broker for the session, found \(brokers.count)")
    for broker in brokers {
        try await broker.stopAndConfirmGone()
    }
}

private func runParityLifecycleSteps(
    executable: URL,
    baseArgs: [String],
    sessionID: String,
    brokerEnv: [String: String]
) async throws {
    let start = try await WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["session-start"] + baseArgs + ["--arg", "session_id=\(sessionID)"],
        environment: brokerEnv
    )
    #expect(start.status == 0, "session-start failed: \(start.stderr)")

    let append = try await WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["memory-append"] + baseArgs + ["--arg", "session_id=\(sessionID)", "session lifecycle smoke"],
        environment: brokerEnv
    )
    #expect(append.status == 0, "memory-append failed: \(append.stderr)")

    let search = try await WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["memory-search"] + baseArgs + ["--arg", "session_id=\(sessionID)", "smoke"],
        environment: brokerEnv
    )
    #expect(search.status == 0, "memory-search failed: \(search.stderr)")
    #expect(search.stdout.contains("session lifecycle"))

    let end = try await WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["session-end"] + baseArgs + ["--arg", "session_id=\(sessionID)"],
        environment: brokerEnv
    )
    #expect(end.status == 0, "session-end failed: \(end.stderr)")
}

@Test func waxCLIParityCommandsRejectDirectStore() async throws {
    let executable = try WaxCLIProcess.builtProductURL()
    let output = try await WaxCLIProcess.run(
        executableURL: executable,
        arguments: ["memory-health", "--direct-store"]
    )
    #expect(output.status != 0)
    #expect(output.stderr.contains("--direct-store is not supported for broker parity commands"))
}

/// A `wax-cli daemon` found by its command line.
private struct PersistentBroker {
    let pid: pid_t
    let socketPath: String?

    /// Broker daemons whose store lives in `storeDirectory`.
    static func find(storeDirectory: URL) async throws -> [PersistentBroker] {
        // pgrep, not a full ps listing: WaxCLIProcess reads output only after
        // the child exits, so output past the pipe buffer would stall it.
        let matches = try await WaxCLIProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", "wax-cli daemon --store-path .*\(storeDirectory.lastPathComponent)"]
        )
        var brokers: [PersistentBroker] = []
        for pid in matches.stdout.split(separator: "\n").compactMap({ pid_t($0) }) {
            let command = try await WaxCLIProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-ww", "-o", "args=", "-p", String(pid)]
            )
            let fields = command.stdout.split(separator: " ").map(String.init)
            let socketPath = fields.firstIndex(of: "--socket-path")
                .flatMap { $0 + 1 < fields.count ? fields[$0 + 1] : nil }
            brokers.append(PersistentBroker(pid: pid, socketPath: socketPath))
        }
        return brokers
    }

    /// SIGTERM is the broker's graceful shutdown. The 30s bound only catches a hang.
    func stopAndConfirmGone() async throws {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(30)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let gone = kill(pid, 0) != 0
        if !gone {
            kill(pid, SIGKILL)
        }
        #expect(gone, "persistent broker \(pid) survived SIGTERM")
        if let socketPath {
            #expect(
                !FileManager.default.fileExists(atPath: socketPath),
                "persistent broker \(pid) left its socket at \(socketPath)"
            )
        }
    }
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
            packageRoot.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/wax-cli"),
            packageRoot.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/wax-cli"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw WaxCLITestError("Build wax-cli before running this test")
    }

    /// Waits for the child on a GCD thread, so a slow wax-cli run never holds a
    /// cooperative thread that the rest of the parallel test run needs.
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> Output {
        try await BlockingWork.run {
            try runBlocking(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }
    }

    private static func runBlocking(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitForExit(timeout: 10)
            throw WaxCLITestError("Process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }
        process.waitForExit(timeout: 10)

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
