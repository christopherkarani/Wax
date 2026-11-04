import ArgumentParser
import Dispatch
import Foundation
import Wax
import WaxCore

extension WaxCLI.MCP {
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate Wax MCP setup and run a tools/list smoke check"
        )

        @Option(name: .customLong("server-path"), help: "Path to wax-mcp binary")
        var serverPath = Pathing.resolveDefaultServerPath()

        @Option(name: .customLong("store-path"), help: "Path to text memory store")
        var storePath = "~/.wax/memory.wax"

        @Option(name: .customLong("license-key"), help: "Wax license key (optional)")
        var licenseKey: String?

        @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder")
        var noEmbedder = false

        @Flag(name: .customLong("feature-license"), help: "Enable license validation during smoke check")
        var featureLicense = false

        @Option(name: .shortAndLong, help: "MCP server name to look up in host configs")
        var name = "wax"

        @OptionGroup var embedderRuntime: EmbedderRuntimeOptions

        mutating func run() throws {
            var failures: [String] = []
            var warnings: [String] = []
            let resolvedServer: String

            do {
                resolvedServer = try Pathing.resolvePath(serverPath)
                if !FileManager.default.isExecutableFile(atPath: resolvedServer) {
                    failures.append("wax-mcp is not executable at \(resolvedServer)")
                }
            } catch {
                // Default path failed — try well-known locations for wax-mcp.
                do {
                    resolvedServer = try resolveToolPath("wax-mcp")
                } catch {
                    failures.append("wax-mcp binary not found at '\(serverPath)' or in common locations")
                    resolvedServer = serverPath
                }
            }

            if !failures.isEmpty {
                // Dependency checks failed — skip server smoke check since dependencies are absent.
                // All failures (including skipped smoke check) are reported below.
                failures.append("Server smoke check skipped (resolve dependency failures above first)")
            }

            if failures.isEmpty {
                if let diskWarning = lowDiskWarning(forStorePath: storePath) {
                    warnings.append(diskWarning)
                }

                let runtimeValidation = try Pathing.validateMCPRuntime(
                    serverPath: resolvedServer,
                    expectVectorRuntime: !noEmbedder
                )
                warnings.append(contentsOf: runtimeValidation.warnings)
                failures.append(contentsOf: runtimeValidation.failures)
            }

            if failures.isEmpty {
                let expandedStore = Pathing.expandPath(storePath)
                let storeURL = URL(fileURLWithPath: expandedStore)
                if (try? StoreLockProbe.tryExclusiveAccess(at: storeURL)) == false {
                    warnings.append(
                        "store is held by another process (likely the HTTP LaunchAgent); smoke-checking an isolated store"
                    )
                    storePath = FileManager.default.temporaryDirectory
                        .appendingPathComponent("wax-doctor-smoke-\(UUID().uuidString).wax")
                        .path
                }

                var env = ProcessInfo.processInfo.environment
                env["WAX_MCP_FEATURE_LICENSE"] = featureLicense ? "1" : "0"
                env.merge(embedderRuntime.resolvedTuning().environmentOverrides(), uniquingKeysWith: { _, new in new })
                if let key = normalizedKey(licenseKey) ?? normalizedKey(ProcessInfo.processInfo.environment["WAX_LICENSE_KEY"]) {
                    env["WAX_LICENSE_KEY"] = key
                }

                var arguments = [
                    "--store-path", Pathing.expandPath(storePath),
                ]
                if noEmbedder {
                    arguments.append("--no-embedder")
                }

                // MCP requires an initialize handshake before any method calls.
                // Send initialize → initialized notification → tools/list so that
                // protocol-compliant servers don't reject the smoke-check request.
                let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wax-doctor","version":"1.0"}}}"# + "\n"
                let initializedNotification = #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"# + "\n"
                let listRequest = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"# + "\n"
                let request = initRequest + initializedNotification + listRequest

                do {
                    // NOTE: `wax-mcp` can shut down on stdin EOF; if we close stdin immediately (as with a
                    // one-shot captured run), the server may exit before background request handlers flush
                    // responses. Keep stdin open until we observe the tools/list response.
                    let output = try ProcessRunner.runMCPSmokeCheck(
                        command: resolvedServer,
                        arguments: arguments,
                        environment: env,
                        input: request,
                        expectedToolNames: MCPDoctorSurface.expectedToolNames(),
                        timeoutSeconds: ProcessRunner.mcpSmokeCheckTimeoutSeconds(
                            environment: ProcessInfo.processInfo.environment
                        )
                    )
                    if output.timedOut {
                        failures.append(
                            "Smoke check timed out waiting for tools/list response. " +
                                smokeCheckFailureContext(output)
                        )
                    } else if output.status != EXIT_SUCCESS {
                        failures.append(
                            "Smoke check failed with exit code \(output.status). " +
                                smokeCheckFailureContext(output)
                        )
                    } else if !output.missingExpectedTools.isEmpty {
                        failures.append(
                            "Smoke check response missing daily tools: " +
                                output.missingExpectedTools.joined(separator: ", ") + ". " +
                                smokeCheckFailureContext(output)
                        )
                    }
                } catch {
                    failures.append("Smoke check failed: \(error.localizedDescription)")
                }
            }

            printHostRegistrationMatrix(name: name)

            for warning in warnings {
                print("WARN: \(warning)")
            }

            if failures.isEmpty {
                print("Doctor passed.")
                return
            }

            for failure in failures {
                print("FAIL: \(failure)")
            }
            throw ExitCode.failure
        }
    }
}

private func lowDiskWarning(forStorePath rawPath: String) -> String? {
    let path = Pathing.normalizePath(rawPath)
    let fileURL = URL(fileURLWithPath: path)
    let directoryURL = fileURL.deletingLastPathComponent()

    #if canImport(Darwin)
    let requestedKeys: Set<URLResourceKey> = [
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]
    #else
    let requestedKeys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
    #endif

    guard let values = try? directoryURL.resourceValues(forKeys: requestedKeys) else {
        return nil
    }

    #if canImport(Darwin)
    let available = values.volumeAvailableCapacity.map(Int64.init) ?? values.volumeAvailableCapacityForImportantUsage
    #else
    let available = values.volumeAvailableCapacity.map(Int64.init)
    #endif

    guard let available else {
        return nil
    }

    let threshold = 256 * 1024 * 1024
    guard available < Int64(threshold) else { return nil }

    let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
    return "Low disk space on the store volume (\(formatted) available). Wax store creation or flushes may fail."
}

enum MCPDoctorSurface {
    static let dailyToolNames = [
        "remember",
        "recall",
        "stats",
    ]

    static let legacyToolNames = [
        "session_open",
        "remember",
        "recall",
        "session_close",
        "stats",
        "memory_get",
        "compact_context",
        "session_resume",
    ]

    static func expectedToolNames(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let raw = environment["WAX_MCP_TOOLS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "legacy":
            return legacyToolNames
        default:
            return dailyToolNames
        }
    }
}

enum MCPVectorHealthDiagnostics {
    struct Report: Equatable, Sendable {
        var healthy: Bool
        var vectorSearchEnabled: Bool
        var queryEmbeddingAvailable: Bool
        var model: String?
        var status: String
        var reason: String
        var framesWithoutVectors: Int
    }

    static func evaluate(
        vectorSearchEnabled: Bool,
        queryEmbeddingAvailable: Bool,
        model: String? = nil,
        embeddingStatus: String? = nil,
        embeddingStatusReason: String? = nil,
        framesWithoutVectors: Int = 0
    ) -> Report {
        let healthy = vectorSearchEnabled && queryEmbeddingAvailable
        let reason: String
        if healthy {
            reason = embeddingStatusReason
                ?? "vector search and query embeddings are available"
        } else if !vectorSearchEnabled {
            reason = embeddingStatusReason ?? "vector search is disabled"
        } else {
            reason = embeddingStatusReason ?? "query embeddings are unavailable"
        }
        let status: String
        if healthy {
            status = "healthy"
        } else {
            let token = embeddingStatus?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let embeddingStatus,
               token != "healthy",
               token != "ready",
               token != "ok",
               token != "" {
                status = embeddingStatus
            } else {
                status = "degraded"
            }
        }
        return Report(
            healthy: healthy,
            vectorSearchEnabled: vectorSearchEnabled,
            queryEmbeddingAvailable: queryEmbeddingAvailable,
            model: model,
            status: status,
            reason: reason,
            framesWithoutVectors: max(0, framesWithoutVectors)
        )
    }
}

private struct MCPSmokeCheckOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    let missingExpectedTools: [String]
    let timedOut: Bool
}

private func smokeCheckFailureContext(_ output: MCPSmokeCheckOutput) -> String {
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

extension ProcessRunner {
    static let mcpSmokeCheckTimeoutEnvKey = "WAX_MCP_DOCTOR_SMOKE_TIMEOUT_SECS"
    static let defaultMCPSmokeCheckTimeoutSeconds: TimeInterval = 5

    /// The `mcp doctor` budget for the server's tools/list response. Operators keep the
    /// 5s default. A loaded host, such as a parallel test run, can raise it through
    /// `WAX_MCP_DOCTOR_SMOKE_TIMEOUT_SECS`. Values that are not positive and finite
    /// fall back to the default.
    static func mcpSmokeCheckTimeoutSeconds(environment: [String: String]) -> TimeInterval {
        guard let raw = environment[mcpSmokeCheckTimeoutEnvKey],
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 0
        else {
            return defaultMCPSmokeCheckTimeoutSeconds
        }
        return seconds
    }

    /// How long the smoke-checked server gets to exit once its stdin closes.
    private static let mcpSmokeCheckExitGraceSeconds: TimeInterval = 5

    fileprivate static func runMCPSmokeCheck(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        input: String,
        expectedToolNames: [String],
        timeoutSeconds: TimeInterval
    ) throws -> MCPSmokeCheckOutput {
        final class SmokeCheckState: @unchecked Sendable {
            private let lock = NSLock()
            private var stdoutAll = Data()
            private var stderrAll = Data()
            private var stdoutPending = Data()
            private var toolsListResponse: String?
            private var missingExpectedTools: [String] = []
            private var signaled = false
            fileprivate let semaphore = DispatchSemaphore(value: 0)

            func signalOnce() {
                lock.lock()
                defer { lock.unlock() }
                guard !signaled else { return }
                signaled = true
                semaphore.signal()
            }

            func appendStdout(_ data: Data, expectedToolNames: [String]) {
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
                        missingExpectedTools = expectedToolNames.filter { name in
                            !line.contains(#""name":"\#(name)""#)
                                && !line.contains(#""name": "\#(name)""#)
                        }
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

            func snapshot() -> (stdout: Data, stderr: Data, toolsListResponse: String?, missingExpectedTools: [String]) {
                lock.lock()
                defer { lock.unlock() }
                return (stdoutAll, stderrAll, toolsListResponse, missingExpectedTools)
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
            state.appendStdout(data, expectedToolNames: expectedToolNames)
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

        // Closing stdin asks the server to exit. One that does not is killed,
        // so doctor cannot hang on it.
        process.waitForExit(timeout: mcpSmokeCheckExitGraceSeconds)

        // Drain any remaining output.
        if let data = try? stdoutPipe.fileHandleForReading.readToEnd() {
            state.appendStdout(data, expectedToolNames: expectedToolNames)
        }
        if let data = try? stderrPipe.fileHandleForReading.readToEnd() {
            state.appendStderr(data)
        }

        let snapshot = state.snapshot()
        let stdout = String(data: snapshot.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: snapshot.stderr, encoding: .utf8) ?? ""

        var missingExpectedTools = snapshot.missingExpectedTools
        if snapshot.toolsListResponse == nil {
            missingExpectedTools = expectedToolNames.filter { name in
                !stdout.contains(#""name":"\#(name)""#)
                    && !stdout.contains(#""name": "\#(name)""#)
            }
        }

        return MCPSmokeCheckOutput(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            missingExpectedTools: missingExpectedTools,
            timedOut: timedOut
        )
    }
}

/// Resolve a tool to its full path, checking PATH first and then well-known locations.
@discardableResult
private func printHostRegistrationMatrix(name: String) {
    print("")
    print("## Host registrations (\(name))")
    print("claude: \(claudeRegistrationStatus(name: name))")
    print("muse: \(museRegistrationStatus(name: name))")
    print("cursor: \(cursorRegistrationStatus(name: name))")
    print("codex: \(codexRegistrationStatus(name: name))")
    print("grok: \(grokRegistrationStatus(name: name))")
    print("opencode: \(opencodeRegistrationStatus(name: name))")
}

private func claudeRegistrationStatus(name: String) -> String {
    guard let claudePath = try? resolveToolPath("claude") else {
        return "claude not installed"
    }
    guard let get = try? ProcessRunner.runCaptured(
        command: claudePath,
        arguments: ["mcp", "get", name],
        timeoutSeconds: 15
    ) else {
        return "check failed"
    }
    let claudeSkills = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
    let skill = skillPresenceNote(skillsDir: claudeSkills)
    if get.status == EXIT_SUCCESS {
        return "registered · skill \(skill)"
    }
    if get.status == 1 {
        return "not registered · skill \(skill)"
    }
    return "check failed (code \(get.status))"
}

private func museRegistrationStatus(name: String) -> String {
    let settingsFile = MuseSetup.settingsURL()
    let skill = skillPresenceNote(skillsDir: MuseSetup.skillsDirectory())
    do {
        if try MuseSetup.hasEntry(name: name, at: settingsFile) {
            return "registered (\(settingsFile.path)) · skill \(skill)"
        }
        return "not registered · skill \(skill)"
    } catch {
        return "unreadable: \(error.localizedDescription)"
    }
}

private func cursorRegistrationStatus(name: String) -> String {
    let configFile = MCPInstallHosts.cursorConfigURL()
    do {
        if try CursorSetup.hasEntry(name: name, at: configFile) {
            return "registered (\(configFile.path))"
        }
        return "not registered"
    } catch {
        return "unreadable: \(error.localizedDescription)"
    }
}

private func codexRegistrationStatus(name: String) -> String {
    let configFile = MCPInstallHosts.codexConfigURL()
    let skill = skillPresenceNote(skillsDir: MCPInstallHosts.codexSkillsDirectory())
    do {
        if try CodexSetup.hasEntry(name: name, at: configFile) {
            return "registered (\(configFile.path)) · skill \(skill)"
        }
        return "not registered · skill \(skill)"
    } catch {
        return "unreadable: \(error.localizedDescription)"
    }
}

private func grokRegistrationStatus(name: String) -> String {
    let configFile = MCPInstallHosts.grokConfigURL()
    do {
        if try GrokSetup.hasEntry(name: name, at: configFile) {
            return "registered (\(configFile.path))"
        }
        return "not registered"
    } catch {
        return "unreadable: \(error.localizedDescription)"
    }
}

private func opencodeRegistrationStatus(name: String) -> String {
    let configFile = MCPInstallHosts.openCodeConfigURL()
    do {
        if try OpenCodeSetup.hasEntry(name: name, at: configFile) {
            return "registered (\(configFile.path))"
        }
        return "not registered"
    } catch {
        return "unreadable: \(error.localizedDescription)"
    }
}

private func skillPresenceNote(skillsDir: URL) -> String {
    let marker = skillsDir.appendingPathComponent("wax-mcp").appendingPathComponent("SKILL.md")
    return FileManager.default.fileExists(atPath: marker.path) ? "present" : "missing"
}
