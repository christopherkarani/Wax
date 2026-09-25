import ArgumentParser
import Dispatch
import Foundation
import Wax
import WaxCore

@main
struct WaxCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wax-cli",
        abstract: "Wax developer CLI",
        version: "0.1.49",
        subcommands: [
            RememberCommand.self,
            RecallCommand.self,
            SearchCommand.self,
            MemoryAppendCommand.self,
            MemorySearchCommand.self,
            MemoryGetCommand.self,
            MemoryPromoteCommand.self,
            PromoteCommand.self,
            MemoryHealthCommand.self,
            KnowledgeCaptureCommand.self,
            CorpusSearchCommand.self,
            DaemonCommand.self,
            StatsCommand.self,
            CompactStoreCommand.self,
            MemoryMaintainCommand.self,
            EmbedBackfillCommand.self,
            VectorHealthCommand.self,
            FlushCommand.self,
            SessionStartCommand.self,
            SessionResumeCommand.self,
            SessionEndCommand.self,
            SessionSynthesizeCommand.self,
            HandoffCommand.self,
            HandoffLatestCommand.self,
            CompactContextCommand.self,
            MarkdownExportCommand.self,
            MarkdownSyncCommand.self,
            TaskStateMigrateCommand.self,
            EntityUpsertCommand.self,
            EntityResolveCommand.self,
            FactAssertCommand.self,
            FactRetractCommand.self,
            FactsQueryCommand.self,
            DemoCommand.self,
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
            subcommands: [
                Serve.self,
                Install.self,
                Doctor.self,
                Uninstall.self,
                Prime.self,
                Checkpoint.self,
                WireHooks.self,
                RunHook.self,
            ]
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
            abstract: "Build and register Wax MCP server in detected hosts (Claude Code, Muse Code, Cursor, Codex, Grok, OpenCode), and stage the wax-mcp agent skill"
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

        @Flag(name: .customLong("skip-skill"), help: "Skip staging/installing the wax-mcp operator skill")
        var skipSkill = false

        @Flag(name: .customLong("skip-muse"), help: "Skip Muse Code registration (legacy; prefer --hosts)")
        var skipMuse = false

        @Option(name: .customLong("hosts"), help: "Hosts: auto (default), all, or comma list: claude,muse,cursor,codex,grok,opencode")
        var hosts = "auto"

        @Flag(name: .customLong("write-toml-config"), help: "Write TOML config blocks for Codex/Grok (default: print the snippet)")
        var writeTOMLConfig = false

        @Flag(name: .customLong("dry-run"), help: "Print commands without executing")
        var dryRun = false

        @Option(
            name: .customLong("write-host-rule"),
            help: "Write the generated host-rule playbook to PATH. Omitted means no write."
        )
        var writeHostRule: String?

        @OptionGroup var embedderRuntime: EmbedderRuntimeOptions

        mutating func run() throws {
            let selection = try MCPInstallHosts.parseSpec(hosts)
            let resolved = try MCPInstallHosts.resolve(spec: selection, skipMuse: skipMuse)
            try MCPInstallHosts.validateName(name)
            let selected = resolved.selected
            let explicitOnly: Bool
            if case .only = selection {
                explicitOnly = true
            } else {
                explicitOnly = false
            }

            let claudePath: String? = try? resolveToolPath("claude")

            let resolvedServer = if dryRun {
                Pathing.normalizePath(serverPath)
            } else {
                try Pathing.resolvePath(serverPath)
            }
            let resolvedCLI = try Pathing.resolveSelfExecutablePath()
            let bundledRuntime = Pathing.bundledRuntimeDirectory(forExecutablePath: resolvedCLI) != nil
            // One env list feeds every host so all registrations share the same server environment.
            var mcpEnv: [(String, String)] = [
                ("WAX_MCP_FEATURE_LICENSE", featureLicense ? "1" : "0")
            ]
            if let key = normalizedKey(licenseKey) ?? normalizedKey(ProcessInfo.processInfo.environment["WAX_LICENSE_KEY"]) {
                mcpEnv.append(("WAX_LICENSE_KEY", key))
            }
            let embedderTuning = embedderRuntime.resolvedTuning()
            for (key, value) in embedderTuning.environmentOverrides().sorted(by: { $0.key < $1.key }) {
                mcpEnv.append((key, value))
            }
            // Name must precede -e flags; claude mcp add treats positional args after -e as env vars.
            var addArguments = [
                "mcp", "add",
                name,
                "-t", "stdio",
                "-s", scope.rawValue,
            ]
            for (key, value) in mcpEnv {
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
            if !dryRun, !MCPInstallHosts.validateServerBinary(serverPath: installRuntime.serverPath) {
                throw CLIError(
                    "MCP server binary at \(installRuntime.serverPath) does not answer --version. " +
                    "It was likely built without the MCPServer trait; re-run install without --skip-build."
                )
            }

            let serverEntry = MuseSetup.makeEntry(
                name: name,
                serverPath: installRuntime.serverPath,
                storePath: Pathing.expandPath(storePath),
                env: mcpEnv,
                noEmbedder: noEmbedder,
                featureLicense: featureLicense
            )
            addArguments.append(contentsOf: ["--", serverEntry.command] + serverEntry.args)

            let removeArguments = ["mcp", "remove", "-s", scope.rawValue, name]
            let skillInstall = try Pathing.prepareWaxMCPSkill(
                cliPath: resolvedCLI,
                serverPath: installRuntime.serverPath,
                dryRun: dryRun,
                skip: skipSkill
            )

            if dryRun {
                if bundledRuntime && !skipBuild {
                    print("# Skipping local swift build because wax-cli is running from bundled waxmcp artifacts.")
                }
                if installRuntime.staged {
                    print("# Staging bundled waxmcp runtime into a stable install path before registration.")
                }
                print("# Would verify \(installRuntime.serverPath) answers --version before registering.")
                if selected.contains(.claude) {
                    if claudePath != nil {
                        print("claude \(removeArguments.joined(separator: " "))")
                        print("claude \(redactedArgumentsForDisplay(addArguments).joined(separator: " "))")
                    } else {
                        print("# 'claude' not found; would skip Claude Code registration.")
                    }
                }
                if selected.contains(.muse) {
                    print("# Would merge mcp_servers.\(name) (stdio \(serverEntry.command)) into \(MuseSetup.settingsURL().path)")
                    if let staged = skillInstall.stagedPath {
                        print("# Would run: muse skills install \(staged) --scope user (best effort)")
                    }
                }
                if selected.contains(.cursor) {
                    print("# Would merge mcpServers.\(name) (stdio \(serverEntry.command)) into \(MCPInstallHosts.cursorConfigURL().path)")
                }
                if selected.contains(.codex) {
                    let configFile = MCPInstallHosts.codexConfigURL()
                    if writeTOMLConfig {
                        print("# Would append [mcp_servers.\(name)] to \(configFile.path)")
                    } else {
                        print("# Would print the Codex snippet for \(configFile.path) (pass --write-toml-config to write it):")
                        print(redactedCodexSnippet(for: serverEntry))
                    }
                }
                if selected.contains(.grok) {
                    let configFile = MCPInstallHosts.grokConfigURL()
                    if writeTOMLConfig {
                        print("# Would append [mcp_servers.\(name)] to \(configFile.path)")
                    } else {
                        print("# Would print the Grok snippet for \(configFile.path) (pass --write-toml-config to write it):")
                        print(redactedGrokSnippet(for: serverEntry))
                    }
                }
                if selected.contains(.opencode) {
                    print("# Would merge mcp.\(name) (local \(serverEntry.command)) into \(MCPInstallHosts.openCodeConfigURL().path)")
                }
                for skip in resolved.skipped {
                    print("# Skipping \(skip.host.rawValue): \(skip.reason).")
                }
                if let writeHostRule {
                    print("# Would write host-rule playbook to \(Pathing.expandPath(writeHostRule))")
                }
                printWaxMCPSkillGuidance(skillInstall, dryRun: true)
                return
            }

            try WaxMCPHostRuleWriter.writeIfRequested(path: writeHostRule)
            for skip in resolved.skipped {
                print("# Skipping \(skip.host.rawValue): \(skip.reason).")
            }

            // Explicitly named hosts fail loud; auto/all warn and continue so
            // one broken host cannot block the others.
            func failHost(_ host: String, _ error: Error) throws {
                if explicitOnly {
                    throw error
                }
                writeStderr("warning: \(host) setup failed: \(error.localizedDescription)")
            }

            var handled = false
            if selected.contains(.claude) {
                if let claudePath {
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
                        if explicitOnly {
                            throw ExitCode(addStatus)
                        }
                        writeStderr(
                            "warning: Claude Code setup failed: 'claude mcp add' exited with code \(addStatus)"
                        )
                    } else {
                        handled = true

                        print("Installed MCP server '\(name)' in scope '\(scope.rawValue)'.")
                        print("Run: claude mcp get \(name)")
                    }
                } else if explicitOnly {
                    throw CLIError("Required tool not found on PATH or common locations: claude")
                } else {
                    writeStderr("warning: 'claude' not found; skipping Claude Code registration.")
                }
            }

            if selected.contains(.muse) {
                let settingsFile = MuseSetup.settingsURL()
                do {
                    let result = try MuseSetup.merge(entry: serverEntry, at: settingsFile)
                    handled = true
                    if result.mutated {
                        print("Registered MCP server '\(name)' in Muse Code (\(settingsFile.path)).")
                    } else {
                        print("Muse Code registration already up to date (\(settingsFile.path)).")
                    }
                } catch {
                    try failHost("Muse Code", error)
                }
            }

            if selected.contains(.cursor) {
                let configFile = MCPInstallHosts.cursorConfigURL()
                do {
                    let result = try CursorSetup.merge(entry: serverEntry, at: configFile)
                    handled = true
                    if result.mutated {
                        print("Registered MCP server '\(name)' in Cursor (\(configFile.path)).")
                    } else {
                        print("Cursor registration already up to date (\(configFile.path)).")
                    }
                } catch {
                    try failHost("Cursor", error)
                }
            }

            if selected.contains(.codex) {
                let configFile = MCPInstallHosts.codexConfigURL()
                if writeTOMLConfig {
                    do {
                        let result = try CodexSetup.write(entry: serverEntry, at: configFile)
                        handled = true
                        if result.mutated {
                            print("Registered MCP server '\(name)' in Codex (\(configFile.path)).")
                        } else {
                            print("Codex registration already up to date (\(configFile.path)).")
                        }
                    } catch {
                        print("Add this block to \(configFile.path) manually:")
                        print(redactedCodexSnippet(for: serverEntry))
                        try failHost("Codex", error)
                    }
                } else {
                    handled = true
                    print("Codex uses \(configFile.path). Add this block (or re-run with --write-toml-config):")
                    print(redactedCodexSnippet(for: serverEntry))
                }
            }

            if selected.contains(.grok) {
                let configFile = MCPInstallHosts.grokConfigURL()
                if writeTOMLConfig {
                    do {
                        let result = try GrokSetup.write(entry: serverEntry, at: configFile)
                        handled = true
                        if result.mutated {
                            print("Registered MCP server '\(name)' in Grok (\(configFile.path)).")
                        } else {
                            print("Grok registration already up to date (\(configFile.path)).")
                        }
                    } catch {
                        print("Add this block to \(configFile.path) manually:")
                        print(redactedGrokSnippet(for: serverEntry))
                        try failHost("Grok", error)
                    }
                } else {
                    handled = true
                    print("Grok uses \(configFile.path). Add this block (or re-run with --write-toml-config):")
                    print(redactedGrokSnippet(for: serverEntry))
                }
            }

            if selected.contains(.opencode) {
                let configFile = MCPInstallHosts.openCodeConfigURL()
                do {
                    let result = try OpenCodeSetup.merge(entry: serverEntry, at: configFile)
                    handled = true
                    if result.mutated {
                        print("Registered MCP server '\(name)' in OpenCode (\(configFile.path)).")
                    } else {
                        print("OpenCode registration already up to date (\(configFile.path)).")
                    }
                } catch {
                    try failHost("OpenCode", error)
                }
            }

            if !handled {
                throw CLIError("MCP install handled no hosts; see warnings above.")
            }

            // Best-effort skill installs run after all host registrations so
            // a slow or prompting skill step cannot block another host.
            if selected.contains(.claude), let claudePath {
                try installWaxMCPSkillWithClaudeIfPossible(
                    claudePath: claudePath,
                    skillInstall: skillInstall
                )
            }
            if selected.contains(.muse) {
                try installWaxMCPSkillWithMuseIfPossible(skillInstall: skillInstall)
            }
            if selected.contains(.codex) {
                installWaxMCPSkillForCodexIfPossible(skillInstall: skillInstall)
            }
            printWaxMCPSkillGuidance(skillInstall, dryRun: false)
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
                        expectedToolNames: MCPDoctorSurface.expectedToolNames()
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

extension WaxCLI.MCP {
    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove Wax MCP server from hosts (Claude Code, Muse Code, Cursor, Codex, Grok, OpenCode)"
        )

        @Option(name: .shortAndLong, help: "MCP server name")
        var name = "wax"

        @Option(name: .customLong("scope"), help: "Claude config scope: local, user, project")
        var scope: WaxCLI.MCPScope = .user

        @Option(name: .customLong("hosts"), help: "Hosts: auto (default), all, or comma list: claude,muse,cursor,codex,grok,opencode")
        var hosts = "auto"

        @Flag(name: .customLong("dry-run"), help: "Print what would be removed without removing")
        var dryRun = false

        mutating func run() throws {
            let selection = try MCPInstallHosts.parseSpec(hosts)
            let resolved = try MCPInstallHosts.resolve(spec: selection, skipMuse: false)
            let selected = resolved.selected
            let explicitOnly: Bool
            if case .only = selection {
                explicitOnly = true
            } else {
                explicitOnly = false
            }

            func failHost(_ host: String, _ error: Error) throws {
                if explicitOnly {
                    throw error
                }
                writeStderr("warning: \(host) removal failed: \(error.localizedDescription)")
            }

            if dryRun {
                for host in selected {
                    switch host {
                    case .claude:
                        print("# Would run: claude mcp remove -s \(scope.rawValue) \(name)")
                    case .muse:
                        print("# Would remove mcp_servers.\(name) from \(MuseSetup.settingsURL().path)")
                    case .cursor:
                        print("# Would remove mcpServers.\(name) from \(MCPInstallHosts.cursorConfigURL().path)")
                    case .codex:
                        print("# Would check [mcp_servers.\(name)] in \(MCPInstallHosts.codexConfigURL().path) (removal is manual)")
                    case .grok:
                        print("# Would check [mcp_servers.\(name)] in \(MCPInstallHosts.grokConfigURL().path) (removal is manual)")
                    case .opencode:
                        print("# Would remove mcp.\(name) from \(MCPInstallHosts.openCodeConfigURL().path)")
                    }
                }
                for skip in resolved.skipped {
                    print("# Skipping \(skip.host.rawValue): \(skip.reason).")
                }
                return
            }

            for skip in resolved.skipped {
                print("# Skipping \(skip.host.rawValue): \(skip.reason).")
            }

            if selected.contains(.claude) {
                if let claudePath = try? resolveToolPath("claude") {
                    let status = try ProcessRunner.run(
                        command: claudePath,
                        arguments: ["mcp", "remove", "-s", scope.rawValue, name],
                        passthrough: false,
                        allowNonZeroExit: true
                    )
                    if status == EXIT_SUCCESS {
                        print("Removed MCP server '\(name)' from Claude Code.")
                    } else if status == 1 {
                        print("Claude Code has no '\(name)' registration to remove.")
                    } else if explicitOnly {
                        throw ExitCode(status)
                    } else {
                        writeStderr("warning: 'claude mcp remove' exited with code \(status)")
                    }
                } else if explicitOnly {
                    throw CLIError("Required tool not found on PATH or common locations: claude")
                } else {
                    writeStderr("warning: 'claude' not found; skipping Claude Code removal.")
                }
            }

            if selected.contains(.muse) {
                let settingsFile = MuseSetup.settingsURL()
                do {
                    let result = try MuseSetup.unmerge(name: name, at: settingsFile)
                    print(
                        result.mutated
                            ? "Removed MCP server '\(name)' from Muse Code (\(settingsFile.path))."
                            : "Muse Code has no '\(name)' registration to remove."
                    )
                } catch {
                    try failHost("Muse Code", error)
                }
            }

            if selected.contains(.cursor) {
                let configFile = MCPInstallHosts.cursorConfigURL()
                do {
                    let result = try CursorSetup.unmerge(name: name, at: configFile)
                    print(
                        result.mutated
                            ? "Removed MCP server '\(name)' from Cursor (\(configFile.path))."
                            : "Cursor has no '\(name)' registration to remove."
                    )
                } catch {
                    try failHost("Cursor", error)
                }
            }

            if selected.contains(.codex) {
                // Uninstall cannot reconstruct the installed entry (server path
                // and store are unknown here), so only a file without any wax
                // table is a clean no-op; anything present needs a human look.
                let configFile = MCPInstallHosts.codexConfigURL()
                do {
                    if try CodexSetup.hasEntry(name: name, at: configFile) {
                        print("Codex still lists [mcp_servers.\(name)] in \(configFile.path); remove that block manually.")
                    } else {
                        print("Codex has no '\(name)' registration to remove.")
                    }
                } catch {
                    try failHost("Codex", error)
                }
            }

            if selected.contains(.grok) {
                let configFile = MCPInstallHosts.grokConfigURL()
                do {
                    if try GrokSetup.hasEntry(name: name, at: configFile) {
                        print("Grok still lists [mcp_servers.\(name)] in \(configFile.path); remove that block manually.")
                    } else {
                        print("Grok has no '\(name)' registration to remove.")
                    }
                } catch {
                    try failHost("Grok", error)
                }
            }

            if selected.contains(.opencode) {
                let configFile = MCPInstallHosts.openCodeConfigURL()
                do {
                    let result = try OpenCodeSetup.unmerge(name: name, at: configFile)
                    print(
                        result.mutated
                            ? "Removed MCP server '\(name)' from OpenCode (\(configFile.path))."
                            : "OpenCode has no '\(name)' registration to remove."
                    )
                } catch {
                    try failHost("OpenCode", error)
                }
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

struct CapturedProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
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
        process.environment = environment ?? ProcessInfo.processInfo.environment

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

        if let input, let stdinPipe {
            if let data = input.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                // Bound the hang: SIGTERM, then a short grace wait. A child
                // that ignores SIGTERM may briefly outlive this call, but the
                // caller never blocks past timeout + grace.
                process.terminate()
                let grace = Date().addingTimeInterval(2.0)
                while process.isRunning, Date() < grace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                throw CLIError("'\(command)' timed out after \(timeoutSeconds) seconds")
            }
        } else {
            process.waitUntilExit()
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CapturedProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    fileprivate static func runMCPSmokeCheck(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        input: String,
        expectedToolNames: [String],
        timeoutSeconds: TimeInterval = 5
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

        // Wait for clean exit.
        process.waitUntilExit()

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

struct MCPInstallRuntime: Equatable {
    let cliPath: String
    let serverPath: String
    let staged: Bool
}

struct MCPSkillInstall: Equatable {
    let skipped: Bool
    let sourcePath: String?
    let stagedPath: String?
    let staged: Bool

    static let skippedResult = MCPSkillInstall(
        skipped: true,
        sourcePath: nil,
        stagedPath: nil,
        staged: false
    )
}

struct MCPRuntimeValidation: Equatable {
    var failures: [String] = []
    var warnings: [String] = []
}

enum WaxMCPHostRuleWriter {
    /// Writes the generated host-rule blob only when `path` is non-empty.
    /// Never overwrites a default machine path by implication.
    static func writeIfRequested(path: String?) throws {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: Pathing.expandPath(path))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WaxMCPAgentPlaybook.projectRules.write(to: url, atomically: true, encoding: .utf8)
        print("Wrote host-rule playbook to \(url.path)")
    }
}

enum WaxMCPAgentPlaybook {
    /// Pasteable AGENTS.md / CLAUDE.md / Cursor rules. Keep in lockstep with
    /// `Resources/skills/public/wax-mcp/references/project-rules.md`.
    static let projectRules = """
        Follow the live Wax MCP server instructions for `remember`, `recall`, and `stats`. Do not invent a `session_id`. Do not load the `wax` or `wax-mcp` skills at session start. `wax` is Swift SDK only; `wax-mcp` is install/doctor only.
        """

    /// Native Hermes identity. Not an MCP session_open paste.
    static let hermesRules = """
        Native Hermes already owns session lifecycle. Call `wax_remember` / `wax_recall` / `wax_stats`. Do not pass a Wax `session_id`. Do not paste the MCP `session_open` loop. Omit `mode` unless you need an override. Omit `scope` for current-project recall; pass `scope=global` for person facts. Empty project recall is a miss. Do not add `wax-memory` to `plugins.enabled`.
        """

    /// Pasteable OpenClaw SOUL.md stanza. Append if missing;
    /// replace an existing `## Memory (Wax)` section.
    static let soulRules = """
        ## Memory (Wax)

        You have Wax. Follow the live MCP server instructions for `remember`, `recall`, and `stats`. Do not invent a `session_id`. Do not load wax-mcp at session start.
        """

    static let githubSkillURL =
        "https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp"
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

    /// Stable skill install path: `~/.local/share/waxmcp/skills/wax-mcp` by default,
    /// or `$WAX_MCP_INSTALL_ROOT/skills/wax-mcp` when the install root is overridden.
    static func stableSkillDirectory(skillName: String = "wax-mcp") -> URL {
        if let raw = ProcessInfo.processInfo.environment["WAX_MCP_INSTALL_ROOT"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: expandPath(trimmed))
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent(skillName, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
    }

    static func isValidSkillDirectory(_ url: URL) -> Bool {
        let skillMarkdown = url.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: skillMarkdown.path)
    }

    /// Resolve the wax-mcp operator skill source directory.
    /// Order: `WAX_MCP_SKILL_SOURCE`, npm package `skills/wax-mcp`, repo
    /// `Resources/skills/public/wax-mcp`, already-staged skill path.
    static func resolveWaxMCPSkillSource(
        cliPath: String? = nil,
        serverPath: String? = nil
    ) -> URL? {
        if let raw = ProcessInfo.processInfo.environment["WAX_MCP_SKILL_SOURCE"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate = URL(fileURLWithPath: expandPath(trimmed)).standardizedFileURL
                if isValidSkillDirectory(candidate) {
                    return candidate
                }
            }
        }

        var candidates: [URL] = []

        let executableHints = [cliPath, serverPath].compactMap { $0 }
        for path in executableHints {
            if let packageRoot = npmPackageRoot(forExecutablePath: path) {
                candidates.append(
                    packageRoot
                        .appendingPathComponent("skills", isDirectory: true)
                        .appendingPathComponent("wax-mcp", isDirectory: true)
                )
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        candidates.append(
            cwd
                .appendingPathComponent("Resources/skills/public/wax-mcp", isDirectory: true)
        )
        candidates.append(
            cwd
                .appendingPathComponent("skills/wax-mcp", isDirectory: true)
        )

        for path in executableHints {
            candidates.append(contentsOf: skillCandidatesWalkingUp(from: URL(fileURLWithPath: normalizePath(path))))
        }
        candidates.append(contentsOf: skillCandidatesWalkingUp(from: cwd))

        candidates.append(stableSkillDirectory())

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if seen.contains(path) { continue }
            seen.insert(path)
            if isValidSkillDirectory(candidate) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private static func npmPackageRoot(forExecutablePath path: String) -> URL? {
        guard let runtimeDir = bundledRuntimeDirectory(forExecutablePath: path) else {
            return nil
        }
        // .../package/dist/darwin-arm64 -> package root
        let distDir = runtimeDir.deletingLastPathComponent()
        guard distDir.lastPathComponent == "dist" else { return nil }
        return distDir.deletingLastPathComponent()
    }

    private static func skillCandidatesWalkingUp(from start: URL) -> [URL] {
        var results: [URL] = []
        var current = start.standardizedFileURL
        if !current.hasDirectoryPath {
            current = current.deletingLastPathComponent()
        }
        for _ in 0..<8 {
            results.append(
                current
                    .appendingPathComponent("Resources/skills/public/wax-mcp", isDirectory: true)
            )
            results.append(
                current
                    .appendingPathComponent("skills/wax-mcp", isDirectory: true)
            )
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return results
    }

    static func prepareWaxMCPSkill(
        cliPath: String,
        serverPath: String,
        dryRun: Bool,
        skip: Bool
    ) throws -> MCPSkillInstall {
        if skip {
            return .skippedResult
        }

        let source = resolveWaxMCPSkillSource(cliPath: cliPath, serverPath: serverPath)
        let target = stableSkillDirectory()

        guard let source else {
            return MCPSkillInstall(
                skipped: false,
                sourcePath: nil,
                stagedPath: isValidSkillDirectory(target) ? target.path : nil,
                staged: false
            )
        }

        if source.standardizedFileURL.path == target.standardizedFileURL.path {
            return MCPSkillInstall(
                skipped: false,
                sourcePath: source.path,
                stagedPath: target.path,
                staged: true
            )
        }

        if !dryRun {
            try stageSkillDirectory(from: source, to: target)
        }

        return MCPSkillInstall(
            skipped: false,
            sourcePath: source.path,
            stagedPath: target.path,
            staged: true
        )
    }

    static func stageSkillDirectory(from sourceDir: URL, to targetDir: URL) throws {
        let fm = FileManager.default
        let standardizedSource = sourceDir.standardizedFileURL
        let standardizedTarget = targetDir.standardizedFileURL
        guard isValidSkillDirectory(standardizedSource) else {
            throw CLIError("Skill source is missing SKILL.md: \(standardizedSource.path)")
        }
        guard standardizedSource.path != standardizedTarget.path else { return }

        let parent = standardizedTarget.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".\(standardizedTarget.lastPathComponent).staging-\(UUID().uuidString)"
        )
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: standardizedSource, to: staging)

        if fm.fileExists(atPath: standardizedTarget.path) {
            try fm.removeItem(at: standardizedTarget)
        }
        try fm.moveItem(at: staging, to: standardizedTarget)
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

private func printWaxMCPSkillGuidance(_ skillInstall: MCPSkillInstall, dryRun: Bool) {
    print("")
    print("## Wax agent skill (recommended)")
    if skillInstall.skipped {
        print("Skill staging skipped (--skip-skill).")
        print("Install manually:")
        print("  claude install-skill \(WaxMCPAgentPlaybook.githubSkillURL)")
        printProjectRulesFallback()
        return
    }

    if let source = skillInstall.sourcePath {
        if dryRun {
            print("# Would stage wax-mcp skill from:")
            print("#   \(source)")
        } else {
            print("Skill source: \(source)")
        }
    } else {
        print("Skill source not found locally. Use the GitHub skill URL below.")
    }

    if let staged = skillInstall.stagedPath {
        if dryRun {
            print("# Would stage skill to:")
            print("#   \(staged)")
            print("claude install-skill \(staged)")
        } else if skillInstall.staged {
            print("Staged skill at: \(staged)")
            print("If Claude Code did not pick it up automatically:")
            print("  claude install-skill \(staged)")
        } else {
            print("Existing skill path: \(staged)")
            print("  claude install-skill \(staged)")
        }
    }

    print("Or from GitHub:")
    print("  claude install-skill \(WaxMCPAgentPlaybook.githubSkillURL)")
    print("")
    print("Note: the `wax` skill is for Swift framework integration.")
    print("      the `wax-mcp` skill is the agent operator playbook for MCP tools.")
    printProjectRulesFallback()
}

private func printProjectRulesFallback() {
    print("")
    print("## Project rules fallback (CLAUDE.md / AGENTS.md / Cursor rules)")
    print("Paste this block if your host does not load skills automatically:")
    print("")
    print("```text")
    print(WaxMCPAgentPlaybook.projectRules)
    print("```")
    print("")
    print("## Hermes / OpenClaw SOUL.md")
    print("Append this section. Do not replace the rest of the soul:")
    print("")
    print("```text")
    print(WaxMCPAgentPlaybook.soulRules)
    print("```")
}

private func installWaxMCPSkillWithClaudeIfPossible(
    claudePath: String,
    skillInstall: MCPSkillInstall
) throws {
    guard !skillInstall.skipped, skillInstall.staged, let stagedPath = skillInstall.stagedPath else {
        return
    }

    let status = try ProcessRunner.run(
        command: claudePath,
        arguments: ["install-skill", stagedPath],
        passthrough: false,
        allowNonZeroExit: true
    )
    if status == EXIT_SUCCESS {
        print("Installed wax-mcp skill into Claude Code from \(stagedPath).")
    } else {
        writeStderr(
            "warning: 'claude install-skill \(stagedPath)' exited with code \(status); install the skill manually if needed."
        )
    }
}

private func installWaxMCPSkillWithMuseIfPossible(skillInstall: MCPSkillInstall) throws {
    guard !skillInstall.skipped, skillInstall.staged, let stagedPath = skillInstall.stagedPath else {
        return
    }

    guard let musePath = try? resolveToolPath("muse") else {
        writeStderr(
            "warning: 'muse' not found; install the wax-mcp skill manually: muse skills install \(stagedPath) --scope user"
        )
        return
    }

    let status = try ProcessRunner.run(
        command: musePath,
        arguments: ["skills", "install", stagedPath, "--scope", "user"],
        passthrough: false,
        allowNonZeroExit: true
    )
    if status == EXIT_SUCCESS {
        print("Installed wax-mcp skill into Muse Code from \(stagedPath).")
    } else {
        writeStderr(
            "warning: 'muse skills install \(stagedPath) --scope user' exited with code \(status); install the skill manually if needed."
        )
    }
}

private func installWaxMCPSkillForCodexIfPossible(skillInstall: MCPSkillInstall) {
    guard !skillInstall.skipped, skillInstall.staged, let stagedPath = skillInstall.stagedPath else {
        return
    }
    let target = MCPInstallHosts.codexSkillsDirectory().appendingPathComponent("wax-mcp")
    if FileManager.default.fileExists(atPath: target.path) {
        print("Codex skill already present at \(target.path).")
        return
    }
    do {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: stagedPath, toPath: target.path)
        print("Installed wax-mcp skill for Codex at \(target.path).")
    } catch {
        writeStderr(
            "warning: Codex skill copy failed: \(error.localizedDescription); copy \(stagedPath) to \(target.path) manually."
        )
    }
}

private func redactedCodexSnippet(for entry: MuseSetup.ServerEntry) -> String {
    CodexSetup.snippet(for: redactedSnippetEntry(entry))
}

private func redactedGrokSnippet(for entry: MuseSetup.ServerEntry) -> String {
    GrokSetup.snippet(for: redactedSnippetEntry(entry))
}

private func redactedSnippetEntry(_ entry: MuseSetup.ServerEntry) -> MuseSetup.ServerEntry {
    MuseSetup.ServerEntry(
        name: entry.name,
        command: entry.command,
        args: entry.args,
        env: entry.env.map { key, value in
            key == "WAX_LICENSE_KEY" ? (key, "***") : (key, value)
        },
        mode: entry.mode
    )
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

func resolveToolPath(_ tool: String) throws -> String {
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
