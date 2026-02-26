#if MCPServer
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MCP
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WaxMCPServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "WaxMCPServer",
        abstract: "Stdio MCP server exposing Wax memory and multimodal RAG tools."
    )

    @Option(name: .customLong("store-path"), help: "Path to the Wax memory store (.wax)")
    var storePath = "~/.wax/memory.wax"

    @Option(name: .customLong("license-key"), help: "Wax license key (fallback: WAX_LICENSE_KEY)")
    var licenseKey: String?

    @Flag(name: .customLong("no-embedder"), help: "Run in text-only mode without MiniLM")
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
                writeStderr("WaxMCPServer failed: \(error)")
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

        let memoryURL = try resolveStoreURL(storePath)

        let embedder = try await buildEmbedder()

        var memoryConfig = OrchestratorConfig.default
        memoryConfig.enableStructuredMemory = featureFlagEnabled(
            "WAX_MCP_FEATURE_STRUCTURED_MEMORY",
            default: true
        )
        memoryConfig.enableAccessStatsScoring = featureFlagEnabled(
            "WAX_MCP_FEATURE_ACCESS_STATS",
            default: false
        )
        if embedder == nil {
            memoryConfig.enableVectorSearch = false
            memoryConfig.rag.searchMode = .textOnly
        }

        writeStderr(
            "WaxMCPServer features: " +
                "structured_memory=\(memoryConfig.enableStructuredMemory) " +
                "access_stats_scoring=\(memoryConfig.enableAccessStatsScoring) " +
                "license_validation=\(licenseEnabled) " +
                "vector_search=\(memoryConfig.enableVectorSearch)"
        )

        let memory = try await MemoryOrchestrator(
            at: memoryURL,
            config: memoryConfig,
            embedder: embedder
        )

        // SYNC: keep this version in sync with npm/waxmcp/package.json "version"
        let serverVersion = "0.1.5"
        writeStderr("WaxMCPServer v\(serverVersion) starting")
        let server = Server(
            name: "WaxMCPServer",
            version: serverVersion,
            instructions: "Use these tools to store, search, and recall Wax memory.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .default
        )
        await WaxMCPTools.register(
            on: server,
            memory: memory,
            structuredMemoryEnabled: memoryConfig.enableStructuredMemory
        )

        // Install signal handlers so SIGINT/SIGTERM trigger graceful shutdown
        // instead of immediate process termination (which would skip flush/close).
        let signalSources = installSignalHandlers(server: server)

        var runError: Error?
        do {
            let transport = StdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            runError = error
        }

        // Cancel signal sources now that we're shutting down.
        for source in signalSources { source.cancel() }

        await server.stop()

        do {
            try await memory.flush()
        } catch {
            if runError == nil {
                runError = error
            } else {
                writeStderr("Memory flush error: \(error)")
            }
        }

        do {
            try await memory.close()
        } catch {
            if runError == nil {
                runError = error
            } else {
                writeStderr("Memory close error: \(error)")
            }
        }

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

    private func resolveStoreURL(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCP.MCPError.invalidParams("Store path cannot be empty")
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    private func buildEmbedder() async throws -> (any EmbeddingProvider)? {
        if noEmbedder {
            return nil
        }

        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        do {
            return try await MiniLMEmbedder.makeCommandLineEmbedder(prewarmBatchSize: 1)
        } catch {
            writeStderr("Warning: MiniLM embedder failed to load (\(error)); falling back to text-only search.")
            return nil
        }
        #else
        return nil
        #endif
    }
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

private func writeStderr(_ message: String) {
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

let message = "WaxMCPServer requires the MCPServer trait. Build with --traits MCPServer.\n"
if let data = message.data(using: .utf8) {
    FileHandle.standardError.write(data)
}
exit(EXIT_FAILURE)
#endif
