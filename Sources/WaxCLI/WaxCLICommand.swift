import ArgumentParser
import Dispatch
import Foundation
import WaxCore

@main
struct WaxCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wax-cli",
        abstract: "Wax developer CLI",
        subcommands: [
            RememberCommand.self,
            RecallCommand.self,
            SearchCommand.self,
            DaemonCommand.self,
            StatsCommand.self,
            VectorHealthCommand.self,
            FlushCommand.self,
            HandoffCommand.self,
            HandoffLatestCommand.self,
            EntityUpsertCommand.self,
            EntityResolveCommand.self,
            FactAssertCommand.self,
            FactRetractCommand.self,
            FactsQueryCommand.self,
            MCP.self,
        ]
    )
}

extension WaxCLI {
    enum MCPScope: String, CaseIterable, ExpressibleByArgument {
        case local
        case user
        case project
    }

    struct MCP: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage Wax MCP server setup and runtime",
            subcommands: [Serve.self, Install.self, Doctor.self, Uninstall.self]
        )
    }
}

extension WaxCLI.MCP {
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the Wax MCP stdio server"
        )

        @Option(name: .customLong("server-path"), help: "Path to wax-mcp binary")
        var serverPath = Pathing.resolveDefaultServerPath()

        @Option(name: .customLong("store-path"), help: "Path to text memory store")
        var storePath = "~/.wax/memory.wax"

        @Option(name: .customLong("license-key"), help: "Wax license key (optional)")
        var licenseKey: String?

        @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder")
        var noEmbedder = false

        @Flag(name: .customLong("feature-license"), help: "Enable license validation (default disabled)")
        var featureLicense = false

        @OptionGroup var embedderRuntime: EmbedderRuntimeOptions

        mutating func run() throws {
            let resolvedServer = try Pathing.resolvePath(serverPath)
            var arguments = [
                "--store-path", Pathing.expandPath(storePath),
            ]
            if noEmbedder {
                arguments.append("--no-embedder")
            }

            var env = ProcessInfo.processInfo.environment
            env["WAX_MCP_FEATURE_LICENSE"] = featureLicense ? "1" : "0"
            if let key = normalizedKey(licenseKey) {
                env["WAX_LICENSE_KEY"] = key
            }
            env.merge(embedderRuntime.resolvedTuning().environmentOverrides(), uniquingKeysWith: { _, new in new })

            let status = try ProcessRunner.run(
                command: resolvedServer,
                arguments: arguments,
                environment: env,
                passthrough: true,
                allowNonZeroExit: true
            )
            if status != EXIT_SUCCESS {
                throw ExitCode(status)
            }
        }
    }
}

extension WaxCLI.MCP {
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build and register Wax MCP server in Claude Code"
        )

        @Option(name: .shortAndLong, help: "MCP server name")
        var name = "wax"

        @Option(name: .customLong("scope"), help: "Claude config scope: local, user, project")
        var scope: WaxCLI.MCPScope = .user

        @Option(name: .customLong("server-path"), help: "Path to wax-mcp binary")
        var serverPath = Pathing.resolveDefaultServerPath()

        @Option(name: .customLong("store-path"), help: "Path to text memory store")
        var storePath = "~/.wax/memory.wax"

        @Option(name: .customLong("license-key"), help: "Wax license key (optional)")
        var licenseKey: String?

        @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder")
        var noEmbedder = false

        @Flag(name: .customLong("feature-license"), help: "Enable license validation (default disabled)")
        var featureLicense = false

        @Flag(name: .customLong("skip-build"), help: "Skip building wax-mcp before install")
        var skipBuild = false

        @Flag(name: .customLong("dry-run"), help: "Print commands without executing")
        var dryRun = false

        @OptionGroup var embedderRuntime: EmbedderRuntimeOptions

        mutating func run() throws {
            let claudePath = if dryRun {
                "claude"
            } else {
                try resolveToolPath("claude")
            }

            let resolvedServer = if dryRun {
                Pathing.normalizePath(serverPath)
            } else {
                try Pathing.resolvePath(serverPath)
            }
            let resolvedCLI = try Pathing.resolveSelfExecutablePath()
            let bundledRuntime = Pathing.bundledRuntimeDirectory(forExecutablePath: resolvedCLI) != nil
            // Name must precede -e flags; claude mcp add treats positional args after -e as env vars.
            var addArguments = [
                "mcp", "add",
                name,
                "-t", "stdio",
                "-s", scope.rawValue,
                "-e", "WAX_MCP_FEATURE_LICENSE=\(featureLicense ? "1" : "0")",
            ]

            if let key = normalizedKey(licenseKey) ?? normalizedKey(ProcessInfo.processInfo.environment["WAX_LICENSE_KEY"]) {
                addArguments.append(contentsOf: ["-e", "WAX_LICENSE_KEY=\(key)"])
            }

            let embedderTuning = embedderRuntime.resolvedTuning()
            for (key, value) in embedderTuning.environmentOverrides().sorted(by: { $0.key < $1.key }) {
                addArguments.append(contentsOf: ["-e", "\(key)=\(value)"])
            }

            if !skipBuild && !bundledRuntime {
                let buildArguments = ["build", "--product", "wax-mcp", "--traits", "default,MCPServer"]
                if dryRun {
                    print("swift \(buildArguments.joined(separator: " "))")
                } else {
                    let buildStatus = try ProcessRunner.run(
                        command: "swift",
                        arguments: buildArguments,
                        passthrough: true,
                        allowNonZeroExit: true
                    )
                    if buildStatus != EXIT_SUCCESS {
                        throw ExitCode(buildStatus)
                    }
                }
            }

            let installRuntime = try Pathing.prepareMCPInstallRuntime(
                cliPath: resolvedCLI,
                serverPath: resolvedServer,
                dryRun: dryRun
            )

            addArguments.append(contentsOf: [
                "--",
                installRuntime.serverPath,
                "--store-path", Pathing.expandPath(storePath),
            ])
            if noEmbedder {
                addArguments.append("--no-embedder")
            }
            if featureLicense {
                addArguments.append("--feature-license")
            }

            let removeArguments = ["mcp", "remove", "-s", scope.rawValue, name]

            if dryRun {
                if bundledRuntime && !skipBuild {
                    print("# Skipping local swift build because wax-cli is running from bundled waxmcp artifacts.")
                }
                if installRuntime.staged {
                    print("# Staging bundled waxmcp runtime into a stable install path before registration.")
                }
                print("claude \(removeArguments.joined(separator: " "))")
                print("claude \(redactedArgumentsForDisplay(addArguments).joined(separator: " "))")
                return
            }

            // Remove the existing registration before re-adding. Exit code 1 is expected
            // when the server is not yet registered (claude mcp remove returns 1 for ENOENT).
            // Any other non-zero exit code indicates an unexpected error (e.g. permissions).
            let removeStatus = try ProcessRunner.run(
                command: claudePath,
                arguments: removeArguments,
                passthrough: false,
                allowNonZeroExit: true
            )
            if removeStatus != EXIT_SUCCESS && removeStatus != 1 {
                writeStderr("warning: 'claude mcp remove' exited with unexpected code \(removeStatus)")
            }

            let addStatus = try ProcessRunner.run(
                command: claudePath,
                arguments: addArguments,
                passthrough: true,
                allowNonZeroExit: true
            )
            if addStatus != EXIT_SUCCESS {
                throw ExitCode(addStatus)
            }

            print("Installed MCP server '\(name)' in scope '\(scope.rawValue)'.")
            print("Run: claude mcp get \(name)")
        }
    }
}

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

            do {
                try resolveToolPath("claude")
            } catch {
                failures.append(error.localizedDescription)
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
                        expectedToolName: "remember"
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
                    } else if !output.foundExpectedTool {
                        failures.append(
                            "Smoke check response missing remember tool. " +
                                smokeCheckFailureContext(output)
                        )
                    }
                } catch {
                    failures.append("Smoke check failed: \(error.localizedDescription)")
                }
            }

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

extension WaxCLI.MCP {
    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove Wax MCP server from Claude Code"
        )

        @Option(name: .shortAndLong, help: "MCP server name")
        var name = "wax"

        @Option(name: .customLong("scope"), help: "Claude config scope: local, user, project")
        var scope: WaxCLI.MCPScope = .user

        mutating func run() throws {
            let claudePath = try resolveToolPath("claude")
            let status = try ProcessRunner.run(
                command: claudePath,
                arguments: ["mcp", "remove", "-s", scope.rawValue, name],
                passthrough: true,
                allowNonZeroExit: true
            )
            if status != EXIT_SUCCESS {
                throw ExitCode(status)
            }
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

private struct CapturedProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct MCPSmokeCheckOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    let foundExpectedTool: Bool
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

private enum ProcessRunner {
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

struct MCPInstallRuntime: Equatable {
    let cliPath: String
    let serverPath: String
    let staged: Bool
}

struct MCPRuntimeValidation: Equatable {
    var failures: [String] = []
    var warnings: [String] = []
}

enum Pathing {
    static func expandPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    static func resolvePath(_ raw: String) throws -> String {
        let path = normalizePath(raw)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        throw CLIError("Path not found: \(url.path)")
    }

    /// Resolves the `wax-mcp` server binary path using a search order:
    /// 1. Sibling `wax-mcp` next to the running CLI binary (production/npm layout)
    /// 2. `.build/debug/wax-mcp` relative to cwd (development)
    static func resolveDefaultServerPath() -> String {
        // 1. Look next to the running binary
        if let selfPath = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = selfPath.appendingPathComponent("wax-mcp").path
            if FileManager.default.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        // 2. Fall back to development build path
        return ".build/debug/wax-mcp"
    }

    static func resolveSelfExecutablePath() throws -> String {
        guard let raw = CommandLine.arguments.first else {
            throw CLIError("Unable to resolve current executable path")
        }

        if raw.contains("/") {
            let path = raw.hasPrefix("/")
                ? raw
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(raw)
                    .standardizedFileURL
                    .path
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }

        let lookup = try ProcessRunner.runCaptured(command: "which", arguments: [raw])
        if lookup.status == EXIT_SUCCESS {
            let resolved = lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                return URL(fileURLWithPath: resolved).resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
        return raw
    }

    static func prepareMCPInstallRuntime(
        cliPath: String,
        serverPath: String,
        dryRun: Bool
    ) throws -> MCPInstallRuntime {
        let cliBundledDir = bundledRuntimeDirectory(forExecutablePath: cliPath)
        let serverBundledDir = bundledRuntimeDirectory(forExecutablePath: serverPath)

        guard let sourceDir = cliBundledDir ?? serverBundledDir else {
            return MCPInstallRuntime(cliPath: cliPath, serverPath: serverPath, staged: false)
        }

        let targetDir = stableRuntimeDirectory(forPlatformDirectory: sourceDir.lastPathComponent)
        if !dryRun {
            let sourceValidation = try validateRuntimeDirectory(
                sourceDir,
                expectVectorRuntime: true
            )
            if !sourceValidation.failures.isEmpty {
                throw CLIError(sourceValidation.failures.joined(separator: " | "))
            }
            try stageBundledRuntimeIfNeeded(from: sourceDir, to: targetDir)
            let stagedValidation = try validateStagedRuntimeCopy(
                sourceDir: sourceDir,
                targetDir: targetDir,
                expectVectorRuntime: true
            )
            if !stagedValidation.failures.isEmpty {
                throw CLIError(stagedValidation.failures.joined(separator: " | "))
            }
        }

        let effectiveCLI = cliBundledDir == sourceDir
            ? targetDir.appendingPathComponent(URL(fileURLWithPath: cliPath).lastPathComponent).path
            : cliPath
        let effectiveServer = serverBundledDir == sourceDir
            ? targetDir.appendingPathComponent(URL(fileURLWithPath: serverPath).lastPathComponent).path
            : serverPath

        return MCPInstallRuntime(
            cliPath: effectiveCLI,
            serverPath: effectiveServer,
            staged: true
        )
    }

    static func bundledRuntimeDirectory(forExecutablePath path: String) -> URL? {
        let executableURL = URL(fileURLWithPath: normalizePath(path)).standardizedFileURL
        let directoryURL = executableURL.deletingLastPathComponent()
        guard directoryURL.deletingLastPathComponent().lastPathComponent == "dist" else {
            return nil
        }

        let platformName = directoryURL.lastPathComponent
        guard platformName.hasPrefix("darwin-") else {
            return nil
        }

        let cliPath = directoryURL.appendingPathComponent("wax-cli").path
        let serverPath = directoryURL.appendingPathComponent("wax-mcp").path
        guard FileManager.default.isExecutableFile(atPath: cliPath),
              FileManager.default.isExecutableFile(atPath: serverPath)
        else {
            return nil
        }

        return directoryURL
    }

    static func runtimeDirectory(forExecutablePath path: String) -> URL? {
        if let bundled = bundledRuntimeDirectory(forExecutablePath: path) {
            return bundled
        }

        let executableURL = URL(fileURLWithPath: normalizePath(path)).standardizedFileURL
        let directoryURL = executableURL.deletingLastPathComponent()
        let cliPath = directoryURL.appendingPathComponent("wax-cli").path
        let serverPath = directoryURL.appendingPathComponent("wax-mcp").path
        guard FileManager.default.fileExists(atPath: cliPath) || FileManager.default.fileExists(atPath: serverPath) else {
            return nil
        }
        return directoryURL
    }

    static func stableRuntimeDirectory(forPlatformDirectory platformDirectory: String) -> URL {
        let root = ProcessInfo.processInfo.environment["WAX_MCP_INSTALL_ROOT"].flatMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: expandPath(trimmed)).standardizedFileURL
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)

        return root.appendingPathComponent(platformDirectory, isDirectory: true)
    }

    static func stageBundledRuntimeIfNeeded(from sourceDir: URL, to targetDir: URL) throws {
        let fm = FileManager.default
        let standardizedSource = sourceDir.standardizedFileURL
        let standardizedTarget = targetDir.standardizedFileURL
        guard standardizedSource.path != standardizedTarget.path else { return }

        let parent = standardizedTarget.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(".\(standardizedTarget.lastPathComponent).staging-\(UUID().uuidString)")
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: standardizedSource, to: staging)
        try adHocSignExecutables(in: staging)
        try refreshRuntimeChecksums(in: staging)

        if fm.fileExists(atPath: standardizedTarget.path) {
            try fm.removeItem(at: standardizedTarget)
        }
        try fm.moveItem(at: staging, to: standardizedTarget)
    }

    static func validateMCPRuntime(
        serverPath: String,
        expectVectorRuntime: Bool
    ) throws -> MCPRuntimeValidation {
        guard let runtimeDirectory = runtimeDirectory(forExecutablePath: serverPath) else {
            return MCPRuntimeValidation()
        }
        return try validateRuntimeDirectory(runtimeDirectory, expectVectorRuntime: expectVectorRuntime)
    }

    private static func validateStagedRuntimeCopy(
        sourceDir: URL,
        targetDir: URL,
        expectVectorRuntime: Bool
    ) throws -> MCPRuntimeValidation {
        var validation = try validateRuntimeDirectory(targetDir, expectVectorRuntime: expectVectorRuntime)
        let sourceEntries = try topLevelRuntimeEntries(in: sourceDir)
        let targetEntries = try topLevelRuntimeEntries(in: targetDir)
        let missing = sourceEntries.subtracting(targetEntries).sorted()
        if !missing.isEmpty {
            validation.failures.append("Staged runtime is missing entries copied from the bundled runtime: \(missing.joined(separator: ", "))")
        }
        return validation
    }

    private static func validateRuntimeDirectory(
        _ directory: URL,
        expectVectorRuntime: Bool
    ) throws -> MCPRuntimeValidation {
        var validation = MCPRuntimeValidation()

        let requiredExecutables = ["wax-cli", "wax-mcp"]
        for executable in requiredExecutables {
            let path = directory.appendingPathComponent(executable).path
            if !FileManager.default.isExecutableFile(atPath: path) {
                validation.failures.append("Runtime is missing executable \(executable) at \(path)")
            }
        }

        for executable in requiredExecutables {
            let executableURL = directory.appendingPathComponent(executable)
            let checksumURL = directory.appendingPathComponent("\(executable).sha256")
            if FileManager.default.fileExists(atPath: checksumURL.path) {
                if !FileManager.default.fileExists(atPath: executableURL.path) {
                    validation.failures.append("Runtime checksum exists for \(executable) but the executable is missing.")
                    continue
                }
                let expected = try readChecksumFile(at: checksumURL)
                let actual = try sha256Hex(for: executableURL)
                if expected.caseInsensitiveCompare(actual) != .orderedSame {
                    validation.failures.append("Runtime checksum mismatch for \(executable) in \(directory.path)")
                }
            }
        }

        let recommendedBundles = [
            "Wax_Wax.bundle",
            "Wax_WaxBertTokenizer.bundle",
            "Wax_WaxVectorSearch.bundle",
            "MetalANNS_MetalANNSCore.bundle",
        ]
        for bundle in recommendedBundles {
            let bundlePath = directory.appendingPathComponent(bundle).path
            if !FileManager.default.fileExists(atPath: bundlePath) {
                validation.warnings.append("Runtime bundle missing: \(bundlePath)")
            }
        }

        if expectVectorRuntime {
            let vectorBundlePath = directory.appendingPathComponent("Wax_WaxVectorSearchMiniLM.bundle").path
            if !FileManager.default.fileExists(atPath: vectorBundlePath) {
                validation.warnings.append("Vector runtime bundle missing: \(vectorBundlePath)")
            }
        }

        return validation
    }

    private static func topLevelRuntimeEntries(in directory: URL) throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(entries.map(\.lastPathComponent))
    }

    private static func readChecksumFile(at url: URL) throws -> String {
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let token = contents.split(whereSeparator: \.isWhitespace).first else {
            throw CLIError("Checksum file is empty at \(url.path)")
        }
        return String(token)
    }

    private static func refreshRuntimeChecksums(in directory: URL) throws {
        let requiredExecutables = ["wax-cli", "wax-mcp"]
        for executable in requiredExecutables {
            let executableURL = directory.appendingPathComponent(executable)
            guard FileManager.default.fileExists(atPath: executableURL.path) else { continue }
            let digest = try sha256Hex(for: executableURL)
            let checksumURL = directory.appendingPathComponent("\(executable).sha256")
            let contents = "\(digest)  \(executable)\n"
            try contents.write(to: checksumURL, atomically: true, encoding: .utf8)
        }
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let output = try ProcessRunner.runCaptured(command: "shasum", arguments: ["-a", "256", url.path])
        guard output.status == EXIT_SUCCESS,
              let token = output.stdout.split(whereSeparator: \.isWhitespace).first else {
            throw CLIError("Unable to compute sha256 for \(url.path)")
        }
        return String(token)
    }

    private static func adHocSignExecutables(in directory: URL) throws {
        #if os(macOS)
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            guard values.isRegularFile == true, values.isExecutable == true else { continue }
            let status = try ProcessRunner.run(
                command: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", entry.path],
                passthrough: false,
                allowNonZeroExit: true
            )
            if status != EXIT_SUCCESS {
                throw CLIError("Failed to ad-hoc sign staged runtime at \(entry.path)")
            }
        }
        #endif
    }
}

private func normalizedKey(_ key: String?) -> String? {
    guard let key else { return nil }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
}

private func redactedArgumentsForDisplay(_ arguments: [String]) -> [String] {
    arguments.map { argument in
        if argument.hasPrefix("WAX_LICENSE_KEY=") {
            return "WAX_LICENSE_KEY=<redacted>"
        }
        return argument
    }
}

/// Resolve a tool to its full path, checking PATH first and then well-known locations.
@discardableResult
private func resolveToolPath(_ tool: String) throws -> String {
    let output = try ProcessRunner.runCaptured(command: "which", arguments: [tool])
    if output.status == EXIT_SUCCESS {
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return path }
    }

    // Check well-known installation paths
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "\(home)/.local/bin/\(tool)",
        "/usr/local/bin/\(tool)",
        "/opt/homebrew/bin/\(tool)",
    ]
    for candidate in candidates {
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    throw CLIError("Required tool not found on PATH or common locations: \(tool)")
}

@available(*, deprecated, renamed: "resolveToolPath")
private func ensureToolExists(_ tool: String) throws {
    try resolveToolPath(tool)
}

struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
