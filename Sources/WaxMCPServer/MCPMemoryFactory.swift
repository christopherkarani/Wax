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
            return DeferredCommandLineEmbedder(kind: .arctic, timeout: timeout)
            #else
            writeStderr("Warning: Arctic embeddings not available in this build. Falling back to text-only search.")
            return nil
            #endif
        }

        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        return DeferredCommandLineEmbedder(kind: .minilm, timeout: timeout)
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

@available(macOS 15.0, iOS 18.0, *)
private actor DeferredCommandLineEmbedder: BatchEmbeddingProvider, QueryAwareEmbeddingProvider {
    enum Kind: Sendable {
        case minilm
        case arctic

        var identity: EmbeddingIdentity {
            switch self {
            case .minilm:
                return EmbeddingIdentity(
                    provider: "Wax",
                    model: "MiniLMAll",
                    dimensions: 384,
                    normalized: true
                )
            case .arctic:
                return EmbeddingIdentity(
                    provider: "Wax",
                    model: "ArcticEmbedS",
                    dimensions: 384,
                    normalized: true
                )
            }
        }

        var normalize: Bool {
            switch self {
            case .minilm:
                return true
            case .arctic:
                return false
            }
        }

        var displayName: String {
            switch self {
            case .minilm:
                return "MiniLM"
            case .arctic:
                return "Arctic"
            }
        }
    }

    nonisolated let dimensions: Int = 384
    nonisolated let normalize: Bool
    nonisolated let identity: EmbeddingIdentity?

    private let kind: Kind
    private let timeout: Duration
    private var provider: (any EmbeddingProvider)?
    private var providerTask: Task<any EmbeddingProvider, Error>?

    init(kind: Kind, timeout: Duration) {
        self.kind = kind
        self.timeout = timeout
        self.normalize = kind.normalize
        self.identity = kind.identity
    }

    func embed(_ text: String) async throws -> [Float] {
        let provider = try await resolvedProvider()
        return try await provider.embed(text)
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let provider = try await resolvedProvider()
        guard let batchProvider = provider as? any BatchEmbeddingProvider else {
            return try await texts.asyncMap { try await provider.embed($0) }
        }
        return try await batchProvider.embed(batch: texts)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        let provider = try await resolvedProvider()
        if let queryAware = provider as? any QueryAwareEmbeddingProvider {
            return try await queryAware.embedQuery(text)
        }
        return try await provider.embed(text)
    }

    private func resolvedProvider() async throws -> any EmbeddingProvider {
        if let provider {
            return provider
        }
        if let providerTask {
            return try await providerTask.value
        }

        let kind = self.kind
        let timeout = self.timeout
        writeStderr("Loading \(kind.displayName) embedder on first vector request...")
        let task = Task<any EmbeddingProvider, Error> {
            try await Self.makeProvider(kind: kind, timeout: timeout)
        }
        providerTask = task

        do {
            let provider = try await task.value
            self.provider = provider
            self.providerTask = nil
            return provider
        } catch {
            self.providerTask = nil
            throw error
        }
    }

    private static func makeProvider(
        kind: Kind,
        timeout: Duration
    ) async throws -> any EmbeddingProvider {
        switch kind {
        case .minilm:
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
            return try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM embedder init") {
                try await MiniLMEmbedder.makeCommandLineEmbedder(
                    prewarmBatchSize: 1,
                    skipPrewarm: true
                )
            }
            #else
            throw WaxError.io("MiniLM embeddings are not available in this build.")
            #endif
        case .arctic:
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            return try await AsyncTimeout.run(timeout: timeout, operation: "Arctic embedder init") {
                try await ArcticEmbedder.makeCommandLineEmbedder(
                    prewarmBatchSize: 1,
                    skipPrewarm: true
                )
            }
            #else
            throw WaxError.io("Arctic embeddings are not available in this build.")
            #endif
        }
    }
}

private extension Array where Element == String {
    func asyncMap<T: Sendable>(
        _ transform: @Sendable (String) async throws -> T
    ) async throws -> [T] {
        var output: [T] = []
        output.reserveCapacity(count)
        for value in self {
            output.append(try await transform(value))
        }
        return output
    }
}
#endif
