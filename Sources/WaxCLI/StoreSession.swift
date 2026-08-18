import Foundation
import Wax
import WaxCore

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

enum StoreSession {
    static let defaultStorePath = "~/.wax/memory.wax"
    private static let defaultLockTimeoutSeconds = 5.0

    /// Whether this binary was compiled with MiniLM embedding support.
    static var miniLMCompiled: Bool {
        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        return true
        #else
        return false
        #endif
    }

    /// Whether this binary was compiled with Arctic Embed Small support.
    static var arcticCompiled: Bool {
        #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
        return true
        #else
        return false
        #endif
    }

    static func resolveURL(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError("Store path cannot be empty")
        }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return url
    }

    private static var waxOptions: WaxOptions {
        var options = WaxOptions()
        options.lockWaitTimeout = lockWaitTimeout
        return options
    }

    private static var lockWaitTimeout: Duration? {
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

    /// Open a memory store with an optional embedder.
    ///
    /// - Parameters:
    ///   - skipPrewarm: Unused for automatic open (compile is process-wide and live-attaches).
    ///     Built-in / require-vector still compiles through embedding readiness.
    ///   - embedderChoice: Which embedder to use: `.minilm` (default) or `.arctic`.
    ///   - requireVector: Fail instead of opening while the provider is loading.
    static func open(
        at url: URL,
        noEmbedder: Bool = false,
        skipPrewarm: Bool = false,
        embedderChoice: EmbedderChoice = .minilm,
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment(),
        requireVector: Bool = false
    ) async throws -> MemoryOrchestrator {
        try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: waxOptions.lockWaitTimeout)
        if requireVector, noEmbedder {
            throw CLIError("Vector search required but --no-embedder was set.")
        }
        _ = skipPrewarm
        let request: EmbeddingOpenRequest
        do {
            request = try HostEmbeddingReadiness.request(
                noEmbedder: noEmbedder,
                requireVector: requireVector,
                embedderChoice: embedderChoice.rawValue,
                options: BuiltInEmbeddingProviderOptions(tuning: embedderTuning)
            )
        } catch {
            throw CLIError(error.localizedDescription)
        }

        var config = OrchestratorConfig.default
        config.enableStructuredMemory = true
        do {
            return try await EmbeddingReadinessBinding.openOrchestrator(
                at: url,
                config: config,
                request: request,
                waxOptions: waxOptions
            )
        } catch {
            if requireVector {
                throw CLIError("Vector search required but \(error.localizedDescription)")
            }
            throw error
        }
    }
}
