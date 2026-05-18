import Foundation
import WaxCore

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

package enum CommandLineEmbedderFactory {
    private static let defaultLockTimeoutSeconds = 2.0

    package static func buildEmbedder(
        noEmbedder: Bool,
        embedderChoice: String,
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> (any EmbeddingProvider)? {
        if noEmbedder {
            return nil
        }

        let choice = embedderChoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard choice == "auto" || choice == "minilm" || choice == "arctic" else {
            throw WaxError.encodingError(reason: "Invalid embedder choice '\(embedderChoice)'. Expected minilm, arctic, or auto.")
        }

        if choice == "arctic" {
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            if #available(macOS 15.0, iOS 18.0, *) {
                return DeferredCommandLineEmbedder(kind: .arctic, tuning: tuning)
            }
            brokerWriteStderr("Warning: Arctic requires macOS 15.0 or iOS 18.0. Falling back to text-only search.")
            return nil
            #else
            brokerWriteStderr("Warning: Arctic embeddings not available in this build. Falling back to text-only search.")
            return nil
            #endif
        }

        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        if #available(macOS 15.0, iOS 18.0, *) {
            return DeferredCommandLineEmbedder(kind: .minilm, tuning: tuning)
        }
        brokerWriteStderr("Warning: MiniLM requires macOS 15.0 or iOS 18.0. Falling back to text-only search.")
        return nil
        #else
        return nil
        #endif
    }

    package static func waxOptions() -> WaxOptions {
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
    }

    private let kind: Kind
    private let tuning: CommandLineEmbedderRuntimeTuning
    private var providerTask: Task<(any EmbeddingProvider)?, Never>?
    private var provider: (any EmbeddingProvider)?

    init(kind: Kind, tuning: CommandLineEmbedderRuntimeTuning) {
        self.kind = kind
        self.tuning = tuning
    }

    nonisolated var executionMode: ProviderExecutionMode { .onDeviceOnly }

    nonisolated var dimensions: Int { 384 }

    nonisolated var normalize: Bool {
        switch kind {
        case .minilm:
            return true
        case .arctic:
            return false
        }
    }

    nonisolated var identity: EmbeddingIdentity? {
        switch kind {
        case .minilm:
            return EmbeddingIdentity(provider: "Wax", model: "MiniLM", dimensions: 384, normalized: true)
        case .arctic:
            return EmbeddingIdentity(provider: "Wax", model: "ArcticEmbedS", dimensions: 384, normalized: true)
        }
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let provider = try await resolvedProvider() else {
            throw BrokerEmbedderError.unavailable
        }
        return try await provider.embed(text)
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        guard let provider = try await resolvedProvider() else {
            throw BrokerEmbedderError.unavailable
        }
        if let batchProvider = provider as? any BatchEmbeddingProvider {
            return try await batchProvider.embed(batch: texts)
        }
        return try await texts.asyncMap { try await provider.embed($0) }
    }

    func embedQuery(_ query: String) async throws -> [Float] {
        guard let provider = try await resolvedProvider() else {
            throw BrokerEmbedderError.unavailable
        }
        if let queryAware = provider as? any QueryAwareEmbeddingProvider {
            return try await queryAware.embedQuery(query)
        }
        return try await provider.embed(query)
    }

    private func resolvedProvider() async throws -> (any EmbeddingProvider)? {
        if let provider {
            return provider
        }
        if let task = providerTask {
            let resolved = await task.value
            provider = resolved
            providerTask = nil
            return resolved
        }

        let task = Task<(any EmbeddingProvider)?, Never> { [kind, tuning] in
            await loadProvider(kind: kind, tuning: tuning)
        }
        providerTask = task
        let resolved = await task.value
        provider = resolved
        providerTask = nil
        return resolved
    }

    private nonisolated func loadProvider(
        kind: Kind,
        tuning: CommandLineEmbedderRuntimeTuning
    ) async -> (any EmbeddingProvider)? {
        await withTaskGroup(of: (any EmbeddingProvider)?.self) { group in
            group.addTask {
                do {
                    switch kind {
                    case .minilm:
                        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
                        return try await MiniLMEmbedder.makeCommandLineEmbedder(
                            prewarmBatchSize: tuning.prewarmBatchSize,
                            skipPrewarm: true,
                            tuning: tuning
                        )
                        #else
                        return nil
                        #endif
                    case .arctic:
                        #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
                        return try await ArcticEmbedder.makeCommandLineEmbedder(
                            prewarmBatchSize: tuning.prewarmBatchSize,
                            skipPrewarm: true,
                            tuning: tuning
                        )
                        #else
                        return nil
                        #endif
                    }
                } catch {
                    brokerWriteStderr("Embedder load failed: \(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: tuning.timeoutDuration)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private enum BrokerEmbedderError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Embedding provider is unavailable."
        }
    }
}

private func brokerWriteStderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

private extension Sequence {
    func asyncMap<T: Sendable>(
        _ transform: (Element) async throws -> T
    ) async throws -> [T] {
        var results: [T] = []
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
