import ArgumentParser
import Dispatch
import Foundation
import Wax
import WaxCore

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
