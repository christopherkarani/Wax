import ArgumentParser
import Dispatch
import Foundation
import Wax
import WaxCore

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

        @Flag(name: .customLong("no-embedder"), help: "Disable the embedder")
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
