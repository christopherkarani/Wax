#if MCPServer
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MCP
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM
#endif

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WaxMCPServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "WaxMCPServer",
        abstract: "Stdio MCP server exposing Wax memory and multimodal RAG tools."
    )

    @Option(name: .customLong("store-path"), help: "Path to the Wax memory store (.mv2s)")
    var storePath = "~/.wax/memory.mv2s"

    @Option(name: .customLong("video-store-path"), help: "Path to the Wax video store (.mv2s)")
    var videoStorePath = "~/.wax/video.mv2s"

    @Option(name: .customLong("photo-store-path"), help: "Path to the Wax photo store (.mv2s)")
    var photoStorePath = "~/.wax/photo.mv2s"

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
        if licenseValidationEnabled() {
            let resolvedLicense = normalizedLicense()
            // LicenseValidator is nonisolated — call directly, no MainActor hop needed.
            try LicenseValidator.validate(key: resolvedLicense)
        }

        let memoryURL = try resolveStoreURL(storePath)
        let videoURL = try resolveStoreURL(videoStorePath)
        let photoURL = try resolveStoreURL(photoStorePath)

        let embedder = try await buildEmbedder()

        var memoryConfig = OrchestratorConfig.default
        if embedder == nil {
            memoryConfig.enableVectorSearch = false
            memoryConfig.rag.searchMode = .textOnly
        }

        let memory = try await MemoryOrchestrator(
            at: memoryURL,
            config: memoryConfig,
            embedder: embedder
        )

        let multimodal = embedder.map(MultimodalAdapter.init(base:))

        let video: VideoRAGOrchestrator? = await {
            guard let multimodal else { return nil }
            do {
                return try await VideoRAGOrchestrator(storeURL: videoURL, embedder: multimodal)
            } catch {
                writeStderr("Video RAG disabled: \(error)")
                return nil
            }
        }()

        let photo: PhotoRAGOrchestrator? = await {
            guard let multimodal else { return nil }
            do {
                return try await PhotoRAGOrchestrator(storeURL: photoURL, embedder: multimodal)
            } catch {
                writeStderr("Photo RAG disabled: \(error)")
                return nil
            }
        }()

        let server = Server(
            name: "WaxMCPServer",
            version: "0.1.0",
            instructions: "Use these tools to store, search, and recall Wax memory.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .default
        )
        await WaxMCPTools.register(on: server, memory: memory, video: video, photo: photo)

        var runError: Error?
        do {
            let transport = StdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            runError = error
        }

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

        if let video {
            do {
                try await video.flush()
            } catch {
                writeStderr("Video flush error: \(error)")
            }
        }

        if let photo {
            do {
                try await photo.flush()
            } catch {
                writeStderr("Photo flush error: \(error)")
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
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WAX_MCP_FEATURE_LICENSE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return false
        }

        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
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

        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
        let embedder = try MiniLMEmbedder()
        try? await embedder.prewarm(batchSize: 4)
        return embedder
        #else
        return nil
        #endif
    }
}

private func writeStderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

WaxMCPServerCommand.main()
#else
import Darwin
import Foundation

let message = "WaxMCPServer requires the MCPServer trait. Build with --traits MCPServer.\n"
if let data = message.data(using: .utf8) {
    FileHandle.standardError.write(data)
}
Darwin.exit(EXIT_FAILURE)
#endif
