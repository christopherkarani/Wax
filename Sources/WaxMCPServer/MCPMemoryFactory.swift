#if MCPServer
import Foundation
import MCP
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

enum MCPPathing {
    static func resolveStoreURL(_ rawPath: String) throws -> URL {
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

    static func resolveDirectoryURL(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCP.MCPError.invalidParams("Directory path cannot be empty")
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }
}

enum MCPMemoryFactory {
    private static let defaultLockTimeoutSeconds = 10.0

    static func openMemory(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        structuredMemoryEnabled: Bool
    ) async throws -> MemoryOrchestrator {
        try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: lockWaitTimeout())
        let embedder = try await buildEmbedder(noEmbedder: noEmbedder, embedderChoice: embedderChoice)
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        config.enableAccessStatsScoring = false
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        return try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder,
            waxOptions: waxOptions()
        )
    }

    static func withOpenMemory<T: Sendable>(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        structuredMemoryEnabled: Bool,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        let memory = try await openMemory(
            at: url,
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            structuredMemoryEnabled: structuredMemoryEnabled
        )

        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func openTextOnlyMemory(at url: URL) async throws -> MemoryOrchestrator {
        try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: lockWaitTimeout())
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.rag.searchMode = .textOnly
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = false
        return try await MemoryOrchestrator(at: url, config: config, waxOptions: waxOptions())
    }

    static func withOpenTextOnlyMemory<T: Sendable>(
        at url: URL,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        let memory = try await openTextOnlyMemory(at: url)
        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func buildEmbedder(
        noEmbedder: Bool,
        embedderChoice: String
    ) async throws -> (any EmbeddingProvider)? {
        if noEmbedder {
            return nil
        }

        let timeout: Duration = {
            let env = ProcessInfo.processInfo.environment
            if let raw = env["WAX_EMBEDDER_TIMEOUT_SECS"],
               let secs = Double(raw),
               secs > 0 {
                return .milliseconds(Int64(secs * 1000))
            }
            return .seconds(30)
        }()

        if embedderChoice.lowercased() == "arctic" {
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            do {
                return try await AsyncTimeout.run(timeout: timeout, operation: "Arctic embedder init") {
                    try await ArcticEmbedder.makeCommandLineEmbedder(prewarmBatchSize: 1)
                }
            } catch let error as AsyncTimeout.TimeoutError {
                writeStderr(
                    "Warning: Arctic embedder timed out after \(timeout) (\(error)); falling back to text-only search."
                )
                return nil
            } catch {
                writeStderr("Warning: Arctic embedder failed to load (\(error)); falling back to text-only search.")
                return nil
            }
            #else
            writeStderr("Warning: Arctic embeddings not available in this build. Falling back to text-only search.")
            return nil
            #endif
        }

        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        do {
            return try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM embedder init") {
                try await MiniLMEmbedder.makeCommandLineEmbedder(prewarmBatchSize: 1)
            }
        } catch let error as AsyncTimeout.TimeoutError {
            writeStderr(
                "Warning: MiniLM embedder timed out after \(timeout) (\(error)); falling back to text-only search."
            )
            return nil
        } catch {
            writeStderr("Warning: MiniLM embedder failed to load (\(error)); falling back to text-only search.")
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func waxOptions() -> WaxOptions {
        var options = WaxOptions()
        options.lockWaitTimeout = lockWaitTimeout()
        return options
    }

    private static func lockWaitTimeout() -> Duration? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WAX_LOCK_TIMEOUT_SECS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .milliseconds(Int64(defaultLockTimeoutSeconds * 1000))
        }
        guard let secs = Double(raw) else {
            return .milliseconds(Int64(defaultLockTimeoutSeconds * 1000))
        }
        guard secs > 0 else { return nil }
        return .milliseconds(Int64(secs * 1000))
    }
}
#endif
