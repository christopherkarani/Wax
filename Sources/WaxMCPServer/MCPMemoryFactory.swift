#if MCPServer
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
    private static let defaultLockTimeoutSeconds = 2.0
    private static let defaultBackgroundWarmupDelayMilliseconds = 250

    static func openMemory(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        structuredMemoryEnabled: Bool
    ) async throws -> MemoryOrchestrator {
        let timeout = lockWaitTimeout()
        do {
            try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: timeout)
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
        let embedder = try await buildEmbedder(noEmbedder: noEmbedder, embedderChoice: embedderChoice)
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        config.enableAccessStatsScoring = false
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        do {
            return try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: embedder,
                waxOptions: waxOptions()
            )
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
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
        let timeout = lockWaitTimeout()
        do {
            try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: timeout)
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.rag.searchMode = .textOnly
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = false
        do {
            return try await MemoryOrchestrator(at: url, config: config, waxOptions: waxOptions())
        } catch {
            throw StoreLockProbe.decorateLockError(
                error,
                at: url,
                timeout: timeout,
                operation: "MCP tool open"
            )
        }
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
        let tuning = CommandLineEmbedderRuntimeTuning.fromEnvironment()

        if embedderChoice.lowercased() == "arctic" {
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            return DeferredCommandLineEmbedder(kind: .arctic, timeout: tuning.timeoutDuration, tuning: tuning)
            #else
            writeStderr("Warning: Arctic embeddings not available in this build. Falling back to text-only search.")
            return nil
            #endif
        }

        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        return DeferredCommandLineEmbedder(kind: .minilm, timeout: tuning.timeoutDuration, tuning: tuning)
        #else
        return nil
        #endif
    }

    static func scheduleBackgroundWarmupIfEnabled(
        for embedder: (any EmbeddingProvider)?
    ) {
        guard backgroundWarmupEnabled() else { return }
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        guard let deferred = embedder as? DeferredCommandLineEmbedder else { return }

        let delay = backgroundWarmupDelay()
        Task.detached(priority: .utility) {
            if let delay {
                try? await Task.sleep(for: delay)
            }
            await deferred.scheduleBackgroundWarmup()
        }
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

    private static func backgroundWarmupEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WAX_MCP_BACKGROUND_PREWARM"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return true
        }

        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }

    private static func backgroundWarmupDelay() -> Duration? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WAX_MCP_BACKGROUND_PREWARM_DELAY_MS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .milliseconds(defaultBackgroundWarmupDelayMilliseconds)
        }
        guard let milliseconds = Double(raw) else {
            return .milliseconds(defaultBackgroundWarmupDelayMilliseconds)
        }
        guard milliseconds > 0 else { return nil }
        return .milliseconds(Int64(milliseconds))
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
    private let tuning: CommandLineEmbedderRuntimeTuning
    private var provider: (any EmbeddingProvider)?
    private var providerTask: Task<any EmbeddingProvider, Error>?
    private var providerTaskToken: UUID?

    init(kind: Kind, timeout: Duration, tuning: CommandLineEmbedderRuntimeTuning) {
        self.kind = kind
        self.timeout = timeout
        self.tuning = tuning
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

    func scheduleBackgroundWarmup() {
        guard provider == nil, providerTask == nil else { return }

        let kind = self.kind
        let timeout = self.timeout
        let tuning = self.tuning
        let token = UUID()
        writeStderr("Scheduling \(kind.displayName) embedder background warmup...")

        let task = Task<any EmbeddingProvider, Error> {
            try await Self.makeProvider(kind: kind, timeout: timeout, skipPrewarm: true, tuning: tuning)
        }
        providerTask = task
        providerTaskToken = token

        Task {
            do {
                let provider = try await task.value
                self.finishBackgroundWarmup(token: token, provider: provider)
            } catch {
                self.finishBackgroundWarmupFailure(token: token, error: error)
            }
        }
    }

    private func resolvedProvider() async throws -> any EmbeddingProvider {
        if let provider {
            return provider
        }
        if let providerTask {
            let provider = try await providerTask.value
            self.provider = provider
            self.providerTask = nil
            self.providerTaskToken = nil
            return provider
        }

        let kind = self.kind
        let timeout = self.timeout
        let tuning = self.tuning
        writeStderr("Loading \(kind.displayName) embedder on first vector request...")
        let task = Task<any EmbeddingProvider, Error> {
            try await Self.makeProvider(kind: kind, timeout: timeout, skipPrewarm: true, tuning: tuning)
        }
        providerTask = task
        providerTaskToken = nil

        do {
            let provider = try await task.value
            self.provider = provider
            self.providerTask = nil
            self.providerTaskToken = nil
            return provider
        } catch {
            self.providerTask = nil
            self.providerTaskToken = nil
            throw error
        }
    }

    private func finishBackgroundWarmup(
        token: UUID,
        provider: any EmbeddingProvider
    ) {
        guard providerTaskToken == token else { return }
        self.provider = provider
        self.providerTask = nil
        self.providerTaskToken = nil
    }

    private func finishBackgroundWarmupFailure(
        token: UUID,
        error: Error
    ) {
        guard providerTaskToken == token else { return }
        self.providerTask = nil
        self.providerTaskToken = nil
        writeStderr("Warning: \(kind.displayName) embedder background warmup failed: \(error)")
    }

    private static func makeProvider(
        kind: Kind,
        timeout: Duration,
        skipPrewarm: Bool,
        tuning: CommandLineEmbedderRuntimeTuning
    ) async throws -> any EmbeddingProvider {
        switch kind {
        case .minilm:
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
            return try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM embedder init") {
                try await MiniLMEmbedder.makeCommandLineEmbedder(
                    prewarmBatchSize: tuning.prewarmBatchSize,
                    skipPrewarm: skipPrewarm,
                    tuning: tuning
                )
            }
            #else
            throw WaxError.io("MiniLM embeddings are not available in this build.")
            #endif
        case .arctic:
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            return try await AsyncTimeout.run(timeout: timeout, operation: "Arctic embedder init") {
                try await ArcticEmbedder.makeCommandLineEmbedder(
                    prewarmBatchSize: tuning.prewarmBatchSize,
                    skipPrewarm: skipPrewarm,
                    tuning: tuning
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
