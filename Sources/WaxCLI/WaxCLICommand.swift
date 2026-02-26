import ArgumentParser
import Foundation

@main
struct WaxCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wax",
        abstract: "Wax developer CLI",
        subcommands: [
            RememberCommand.self,
            RecallCommand.self,
            SearchCommand.self,
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

        @Option(name: .customLong("server-path"), help: "Path to WaxMCPServer binary")
        var serverPath = ".build/debug/WaxMCPServer"

        @Option(name: .customLong("store-path"), help: "Path to text memory store")
        var storePath = "~/.wax/memory.wax"

        @Option(name: .customLong("license-key"), help: "Wax license key (optional)")
        var licenseKey: String?

        @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder")
        var noEmbedder = false

        @Flag(name: .customLong("feature-license"), help: "Enable license validation (default disabled)")
        var featureLicense = false

        mutating func run() throws {
            let resolvedServer = try Pathing.resolvePath(serverPath)
            var arguments = [
                "--store-path", Pathing.expandPath(storePath),
            ]
            if noEmbedder {
                arguments.append("--no-embedder")
            }
            if let key = normalizedKey(licenseKey) {
                arguments.append(contentsOf: ["--license-key", key])
            }

            var env = ProcessInfo.processInfo.environment
            env["WAX_MCP_FEATURE_LICENSE"] = featureLicense ? "1" : "0"

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

        @Option(name: .customLong("server-path"), help: "Path to WaxMCPServer binary")
        var serverPath = ".build/debug/WaxMCPServer"

        @Option(name: .customLong("store-path"), help: "Path to text memory store")
        var storePath = "~/.wax/memory.wax"

        @Option(name: .customLong("license-key"), help: "Wax license key (optional)")
        var licenseKey: String?

        @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder")
        var noEmbedder = false

        @Flag(name: .customLong("feature-license"), help: "Enable license validation (default disabled)")
        var featureLicense = false

        @Flag(name: .customLong("skip-build"), help: "Skip building WaxMCPServer before install")
        var skipBuild = false

        @Flag(name: .customLong("dry-run"), help: "Print commands without executing")
        var dryRun = false

        mutating func run() throws {
            if !dryRun {
                try ensureToolExists("claude")
            }

            if !skipBuild {
                let buildArguments = ["build", "--product", "WaxMCPServer", "--traits", "default,MCPServer"]
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

            let resolvedServer = if dryRun {
                Pathing.normalizePath(serverPath)
            } else {
                try Pathing.resolvePath(serverPath)
            }
            let resolvedCLI = try Pathing.resolveSelfExecutablePath()
            var addArguments = [
                "mcp", "add",
                "--transport", "stdio",
                "--scope", scope.rawValue,
                "--env", "WAX_MCP_FEATURE_LICENSE=\(featureLicense ? "1" : "0")",
            ]

            if let key = normalizedKey(licenseKey) ?? normalizedKey(ProcessInfo.processInfo.environment["WAX_LICENSE_KEY"]) {
                addArguments.append(contentsOf: ["--env", "WAX_LICENSE_KEY=\(key)"])
            }

            addArguments.append(contentsOf: [
                name,
                "--",
                resolvedCLI,
                "mcp", "serve",
                "--server-path", resolvedServer,
                "--store-path", Pathing.expandPath(storePath),
            ])
            if noEmbedder {
                addArguments.append("--no-embedder")
            }
            if featureLicense {
                addArguments.append("--feature-license")
            }

            let removeArguments = ["mcp", "remove", "--scope", scope.rawValue, name]

            if dryRun {
                print("claude \(removeArguments.joined(separator: " "))")
                print("claude \(addArguments.joined(separator: " "))")
                return
            }

            // Remove the existing registration before re-adding. Exit code 1 is expected
            // when the server is not yet registered (claude mcp remove returns 1 for ENOENT).
            // Any other non-zero exit code indicates an unexpected error (e.g. permissions).
            let removeStatus = try ProcessRunner.run(
                command: "claude",
                arguments: removeArguments,
                passthrough: false,
                allowNonZeroExit: true
            )
            if removeStatus != EXIT_SUCCESS && removeStatus != 1 {
                fputs("warning: 'claude mcp remove' exited with unexpected code \(removeStatus)\n", stderr)
            }

            let addStatus = try ProcessRunner.run(
                command: "claude",
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

        @Option(name: .customLong("server-path"), help: "Path to WaxMCPServer binary")
        var serverPath = ".build/debug/WaxMCPServer"

        @Option(name: .customLong("store-path"), help: "Path to text memory store")
        var storePath = "~/.wax/memory.wax"

        @Option(name: .customLong("license-key"), help: "Wax license key (optional)")
        var licenseKey: String?

        @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder")
        var noEmbedder = false

        @Flag(name: .customLong("feature-license"), help: "Enable license validation during smoke check")
        var featureLicense = false

        mutating func run() throws {
            var failures: [String] = []
            let resolvedServer: String

            do {
                resolvedServer = try Pathing.resolvePath(serverPath)
                if !FileManager.default.isExecutableFile(atPath: resolvedServer) {
                    failures.append("WaxMCPServer is not executable at \(resolvedServer)")
                }
            } catch {
                failures.append("WaxMCPServer binary not found: \(error.localizedDescription)")
                resolvedServer = serverPath
            }

            do {
                try ensureToolExists("claude")
            } catch {
                failures.append(error.localizedDescription)
            }

            if !failures.isEmpty {
                // Dependency checks failed — skip server smoke check since dependencies are absent.
                // All failures (including skipped smoke check) are reported below.
                failures.append("Server smoke check skipped (resolve dependency failures above first)")
            }

            if failures.isEmpty {
                var env = ProcessInfo.processInfo.environment
                env["WAX_MCP_FEATURE_LICENSE"] = featureLicense ? "1" : "0"
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
                    let output = try ProcessRunner.runCaptured(
                        command: resolvedServer,
                        arguments: arguments,
                        environment: env,
                        input: request
                    )
                    if output.status != EXIT_SUCCESS {
                        failures.append("Smoke check failed with exit code \(output.status)")
                    } else {
                        // The server emits one JSON-RPC response per request (newline-delimited).
                        // id:1 → initialize response, id:2 → tools/list response.
                        // We check the tools/list response specifically to avoid false positives
                        // from the initialize response containing the tool name incidentally.
                        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: true)
                        let toolsListResponse = lines.first(where: { $0.contains(#""id":2"#) || $0.contains(#""id": 2"#) })
                        let responseToCheck = toolsListResponse.map(String.init) ?? String(output.stdout)
                        if !responseToCheck.contains(#""name":"wax_remember""#) {
                            failures.append("Smoke check response missing wax_remember tool")
                        }
                    }
                } catch {
                    failures.append("Smoke check failed: \(error.localizedDescription)")
                }
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
            try ensureToolExists("claude")
            let status = try ProcessRunner.run(
                command: "claude",
                arguments: ["mcp", "remove", "--scope", scope.rawValue, name],
                passthrough: true,
                allowNonZeroExit: true
            )
            if status != EXIT_SUCCESS {
                throw ExitCode(status)
            }
        }
    }
}

private struct CapturedProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
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
}

private enum Pathing {
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
            return path
        }

        let lookup = try ProcessRunner.runCaptured(command: "which", arguments: [raw])
        if lookup.status == EXIT_SUCCESS {
            let resolved = lookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                return resolved
            }
        }
        return raw
    }
}

private func normalizedKey(_ key: String?) -> String? {
    guard let key else { return nil }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
}

private func ensureToolExists(_ tool: String) throws {
    let output = try ProcessRunner.runCaptured(command: "which", arguments: [tool])
    if output.status != EXIT_SUCCESS {
        throw CLIError("Required tool not found on PATH: \(tool)")
    }
}

struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
