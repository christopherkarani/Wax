#if MCPServer
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MCP
import Wax
import WaxCore

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WaxMCPServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wax-mcp",
        abstract: "Stdio MCP server exposing Wax memory and multimodal RAG tools."
    )

    @Option(name: .customLong("store-path"), help: "Path to the Wax memory store (.wax)")
    var storePath = "~/.wax/memory.wax"

    @Option(name: .customLong("license-key"), help: "Wax license key (fallback: WAX_LICENSE_KEY)")
    var licenseKey: String?

    @Option(name: .customLong("embedder"), help: "Embedding provider: minilm (default) or arctic")
    var embedderChoice: String = "minilm"

    @Flag(name: .customLong("no-embedder"), help: "Run in text-only mode without any embedder")
    var noEmbedder = false

    mutating func run() throws {
        let command = self
        Task(priority: .userInitiated) {
            do {
                try await command.runServer()
                Darwin.exit(EXIT_SUCCESS)
            } catch let error as LicenseValidator.ValidationError {
                writeStderr(error.localizedDescription)
                Darwin.exit(EXIT_FAILURE)
            } catch {
                writeStderr("wax-mcp failed: \(error)")
                Darwin.exit(EXIT_FAILURE)
            }
        }

        dispatchMain()
    }

    private func runServer() async throws {
        let licenseEnabled = licenseValidationEnabled()
        if licenseEnabled {
            let resolvedLicense = normalizedLicense()
            // LicenseValidator is nonisolated — call directly, no MainActor hop needed.
            try LicenseValidator.validate(key: resolvedLicense)
        }

        var memoryConfig = OrchestratorConfig.default
        memoryConfig.enableStructuredMemory = featureFlagEnabled(
            "WAX_MCP_FEATURE_STRUCTURED_MEMORY",
            default: true
        )
        memoryConfig.enableAccessStatsScoring = featureFlagEnabled(
            "WAX_MCP_FEATURE_ACCESS_STATS",
            default: false
        )

        let currentExecutablePath = try resolveCurrentExecutablePath()
        let embedderTuning = CommandLineEmbedderRuntimeTuning.fromEnvironment()
        let brokerConfiguration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: AgentBrokerPathing.resolveBrokerCLIPath(currentExecutablePath: currentExecutablePath),
            storePath: storePath,
            embedderChoice: embedderChoice,
            noEmbedder: noEmbedder,
            requireVector: false,
            embedderTuning: embedderTuning
        )
        let brokerStarted = try await AgentBrokerClient.ensureAvailable(configuration: brokerConfiguration)
        defer {
            if brokerStarted {
                try? AgentBrokerClient.shutdownOwnedBrokerIfReachable(configuration: brokerConfiguration)
            }
        }

        let activeToolNames = ToolSchemas.tools(structuredMemoryEnabled: memoryConfig.enableStructuredMemory)
            .map(\.name)

        writeStderr(
            "wax-mcp config: broker=\"\(brokerConfiguration.socketPath)\" store=\"\(brokerConfiguration.storePath)\" " +
                "structuredMemory=\(memoryConfig.enableStructuredMemory) " +
                "accessStatsScoring=\(memoryConfig.enableAccessStatsScoring) " +
                "licenseValidation=\(licenseEnabled) " +
                "vectorSearch=\(!noEmbedder) " +
                "embedder=\(noEmbedder ? "text-only" : embedderChoice.lowercased())"
        )
        writeStderr("wax-mcp toolset: \(activeToolNames.joined(separator: ","))")

        // SYNC: keep this version in sync with Resources/npm/waxmcp/package.json "version"
        let serverVersion = "0.1.20"
        writeStderr("wax-mcp v\(serverVersion) starting")
        let server = Server(
            name: "wax-mcp",
            version: serverVersion,
            instructions: "Use these tools to store, search, and recall Wax memory. Server v\(serverVersion).",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .default
        )
        await WaxMCPTools.register(
            on: server,
            brokerConfiguration: brokerConfiguration,
            structuredMemoryEnabled: memoryConfig.enableStructuredMemory,
            noEmbedder: noEmbedder
        )

        // Install signal handlers so SIGINT/SIGTERM trigger graceful shutdown
        // instead of immediate process termination (which would skip flush/close).
        let signalSources = installSignalHandlers(server: server)

        var runError: Error?
        do {
            let transport = GracefulStdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            runError = error
        }

        // Cancel signal sources now that we're shutting down.
        for source in signalSources { source.cancel() }

        await server.stop()

        if let runError {
            throw runError
        }
    }

    private func normalizedLicense() -> String? {
        if let licenseKey {
            return licenseKey
        }
        return ProcessInfo.processInfo.environment["WAX_LICENSE_KEY"]
    }

    private func licenseValidationEnabled() -> Bool {
        featureFlagEnabled("WAX_MCP_FEATURE_LICENSE", default: false)
    }

    private func featureFlagEnabled(_ key: String, default defaultValue: Bool) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return defaultValue
        }

        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private func resolveCurrentExecutablePath() throws -> String {
        guard let raw = CommandLine.arguments.first else {
            throw MCP.MCPError.internalError("Unable to resolve current executable path")
        }
        if raw.contains("/") {
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
        }
        if let resolved = resolveExecutableOnPath(named: raw) {
            return resolved.path
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return currentDirectory.appendingPathComponent(raw).standardizedFileURL.path
    }

}

private func resolveExecutableOnPath(named executable: String) -> URL? {
    let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":", omittingEmptySubsequences: false)
        .map(String.init)

    let fileManager = FileManager.default
    for entry in pathEntries {
        let directoryURL = entry.isEmpty
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            : URL(fileURLWithPath: entry, isDirectory: true)
        let candidate = directoryURL.appendingPathComponent(executable)
        guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
        return candidate.resolvingSymlinksInPath().standardizedFileURL
    }
    return nil
}

private func installSignalHandlers(server: Server) -> [DispatchSourceSignal] {
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            writeStderr("Received signal \(sig), shutting down gracefully…")
            Task { await server.stop() }
        }
        source.resume()
        sources.append(source)
    }
    return sources
}

func writeStderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

WaxMCPServerCommand.main()
#else
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

let message = "wax-mcp requires the MCPServer trait. Build with --traits MCPServer.\n"
if let data = message.data(using: .utf8) {
    FileHandle.standardError.write(data)
}
exit(EXIT_FAILURE)
#endif
