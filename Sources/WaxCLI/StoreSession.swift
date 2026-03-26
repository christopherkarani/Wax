import Foundation
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

// MARK: - OnceContinuation

/// A thread-safe wrapper that ensures a `CheckedContinuation` is resumed exactly once.
///
/// Used to race two unstructured Tasks (embedder init + timeout) against a shared
/// continuation.  Whichever Task wins calls `resume(returning:)` first; subsequent
/// calls from the "loser" are no-ops.  Returns `true` when the call was the winning
/// resume, `false` if the continuation had already been resumed.
private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let cont = continuation else { return false }
        continuation = nil
        cont.resume(returning: value)
        return true
    }
}

private enum EmbedderLoadResult {
    case disabled
    case ready(any EmbeddingProvider)
    case unavailable(String)
}

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

    /// Timeout for MiniLM embedder initialisation (nanoseconds).
    ///
    /// CoreML model loading is not cooperatively cancellable, so without an explicit
    /// deadline the CLI hangs indefinitely in some environments (sandboxed, first-boot,
    /// slow ANE scheduling). If the embedder doesn't become ready within this window
    /// we fall back to text-only search and print a warning to stderr.
    ///
    /// Override at runtime with the `WAX_EMBEDDER_TIMEOUT_SECS` environment variable.
    private static var embedderTimeoutNS: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["WAX_EMBEDDER_TIMEOUT_SECS"],
           let secs = Double(raw), secs > 0 {
            return UInt64(secs * 1_000_000_000)
        }
        return 30_000_000_000 // 30 seconds default
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
    ///   - skipPrewarm: Skip the prewarm step to reduce cold-start latency.
    ///     Use `true` for write-only operations (remember, handoff) where the first real
    ///     embedding will warm the model naturally.
    ///   - embedderChoice: Which embedder to use: `.minilm` (default) or `.arctic`.
    ///   - requireVector: Fail instead of silently falling back to text-only search.
    static func open(
        at url: URL,
        noEmbedder: Bool = false,
        skipPrewarm: Bool = false,
        embedderChoice: EmbedderChoice = .minilm,
        requireVector: Bool = false
    ) async throws -> MemoryOrchestrator {
        try StoreLockProbe.preflightExclusiveAccess(at: url, timeout: waxOptions.lockWaitTimeout)
        let embedderLoad = try await loadEmbedder(
            noEmbedder: noEmbedder,
            skipPrewarm: skipPrewarm,
            embedderChoice: embedderChoice
        )
        let embedder: (any EmbeddingProvider)?
        switch embedderLoad {
        case .disabled:
            if requireVector {
                throw CLIError("Vector search required but --no-embedder was set.")
            }
            embedder = nil
        case .ready(let loadedEmbedder):
            embedder = loadedEmbedder
        case .unavailable(let reason):
            if requireVector {
                throw CLIError("Vector search required but \(reason)")
            }
            writeStderr("Warning: \(reason). Falling back to text-only search.")
            embedder = nil
        }

        var config = OrchestratorConfig.default
        config.enableStructuredMemory = true
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        return try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder,
            waxOptions: waxOptions
        )
    }

    private static func loadEmbedder(
        noEmbedder: Bool,
        skipPrewarm: Bool,
        embedderChoice: EmbedderChoice
    ) async throws -> EmbedderLoadResult {
        guard !noEmbedder else { return .disabled }

        switch embedderChoice {
        case .arctic:
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            if !skipPrewarm {
                writeStderr("Loading Arctic embedder...")
            }

            let embedder: ArcticEmbedder? = await withCheckedContinuation { cont in
                let once = OnceContinuation<ArcticEmbedder?>(cont)
                let timeoutNS = embedderTimeoutNS

                Task {
                    do {
                        let embedder = try await ArcticEmbedder.makeCommandLineEmbedder(
                            prewarmBatchSize: 1,
                            skipPrewarm: skipPrewarm
                        )
                        once.resume(returning: embedder)
                    } catch {
                        writeStderr("Arctic embedder failed to load: \(error.localizedDescription)")
                        once.resume(returning: nil)
                    }
                }

                Task {
                    try? await Task.sleep(nanoseconds: timeoutNS)
                    if once.resume(returning: nil) {
                        let secs = Int(timeoutNS / 1_000_000_000)
                        writeStderr("Arctic embedder timed out after \(secs)s")
                    }
                }
            }

            if let embedder {
                return .ready(embedder)
            }
            let secs = Int(embedderTimeoutNS / 1_000_000_000)
            return .unavailable(
                "Arctic embedder is unavailable or timed out after \(secs)s"
            )
            #else
            return .unavailable("Arctic embeddings are not available in this build")
            #endif
        case .minilm:
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
            if !skipPrewarm {
                writeStderr("Loading MiniLM embedder...")
            }

            let embedder: MiniLMEmbedder? = await withCheckedContinuation { cont in
                let once = OnceContinuation<MiniLMEmbedder?>(cont)
                let timeoutNS = embedderTimeoutNS

                Task {
                    do {
                        let embedder = try await MiniLMEmbedder.makeCommandLineEmbedder(
                            prewarmBatchSize: 1,
                            skipPrewarm: skipPrewarm
                        )
                        once.resume(returning: embedder)
                    } catch {
                        writeStderr("MiniLM embedder failed to load: \(error.localizedDescription)")
                        once.resume(returning: nil)
                    }
                }

                Task {
                    try? await Task.sleep(nanoseconds: timeoutNS)
                    if once.resume(returning: nil) {
                        let secs = Int(timeoutNS / 1_000_000_000)
                        writeStderr("MiniLM embedder timed out after \(secs)s")
                    }
                }
            }

            if let embedder {
                return .ready(embedder)
            }
            let secs = Int(embedderTimeoutNS / 1_000_000_000)
            return .unavailable(
                "MiniLM embedder is unavailable or timed out after \(secs)s"
            )
            #else
            return .unavailable("MiniLM embeddings are not available in this build")
            #endif
        }
    }
}
