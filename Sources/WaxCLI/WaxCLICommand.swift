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
