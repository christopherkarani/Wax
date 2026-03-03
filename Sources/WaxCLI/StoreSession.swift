import Foundation
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

enum StoreSession {
    static let defaultStorePath = "~/.wax/memory.wax"

    /// Whether this binary was compiled with MiniLM embedding support.
    static var miniLMCompiled: Bool {
        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
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

    /// Open a memory store with an optional embedder.
    ///
    /// - Parameter skipPrewarm: Skip the MiniLM prewarm step to reduce cold-start latency.
    ///   Use `true` for write-only operations (remember, handoff) where the first real
    ///   embedding will warm the model naturally.
    static func open(at url: URL, noEmbedder: Bool = false, skipPrewarm: Bool = false) async throws -> MemoryOrchestrator {
        let embedder: (any EmbeddingProvider)? = try await {
            guard !noEmbedder else { return nil }
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
            do {
                if !skipPrewarm {
                    fputs("Loading MiniLM embedder...\n", stderr)
                }
                let e = try await MiniLMEmbedder.makeCommandLineEmbedder(
                    prewarmBatchSize: 1,
                    skipPrewarm: skipPrewarm
                )
                return e
            } catch {
                fputs("Warning: MiniLM embedder failed to load (\(error)); falling back to text-only search.\n", stderr)
                return nil
            }
            #else
            if !noEmbedder {
                fputs("Note: MiniLM not available in this build. Falling back to text-only search.\n", stderr)
            }
            return nil
            #endif
        }()

        var config = OrchestratorConfig.default
        config.enableStructuredMemory = true
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    }
}
