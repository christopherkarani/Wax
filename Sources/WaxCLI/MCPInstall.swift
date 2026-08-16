import ArgumentParser
import Dispatch
import Foundation
import WaxCore

extension WaxCLI.MCP {
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build and register Wax MCP server in Claude Code, and stage the wax-mcp agent skill"
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
                print("claude \(removeArguments.joined(separator: " "))")
                print("claude \(redactedArgumentsForDisplay(addArguments).joined(separator: " "))")
                printWaxMCPSkillGuidance(skillInstall, dryRun: true)
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
            try installWaxMCPSkillWithClaudeIfPossible(
                claudePath: claudePath,
                skillInstall: skillInstall
            )
            printWaxMCPSkillGuidance(skillInstall, dryRun: false)
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

enum WaxMCPAgentPlaybook {
    /// Pasteable project rules for CLAUDE.md / AGENTS.md hosts.
    /// Verb map (agent `remember`/`recall` vs public `Memory.save`/`search`) is documented once in
    /// `Resources/skills/public/wax/references/public-api.md` and `MCPAgentInstructions`.
    static let projectRules = """
        Use the Wax MCP server for persistent memory in this repo.

        Workflow rules:
        - At session start, call `handoff_latest` first to load prior context, then call `session_start` once and keep the returned `session_id`.
        - Use `remember` to store decisions, discoveries, and short factual notes (public Swift apps use `Memory.save`). If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
        - Use `recall` for assembled context and `search` for raw ranked hits (public Swift apps use `Memory.search`).
        - Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
        - Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores.
        - Use `handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `session_end`.
        - Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
        - Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.

        Behavior expectations:
        - Read existing handoffs and recall results before asking me to restate prior context.
        - Keep memory writes concise, factual, and scoped to the task.
        - When a cross-session result looks relevant, cite the provenance metadata so we know which session store it came from.
        """

    static let githubSkillURL =
        "https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp"
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

/// Resolve a tool to its full path, checking PATH first and then well-known locations.
