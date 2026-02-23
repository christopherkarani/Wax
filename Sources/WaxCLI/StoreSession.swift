import Foundation
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM
#endif

enum StoreSession {
    static let defaultStorePath = "~/.wax/memory.mv2s"

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

    static func open(at url: URL, noEmbedder: Bool = false) async throws -> MemoryOrchestrator {
        let embedder: (any EmbeddingProvider)? = try await {
            guard !noEmbedder else { return nil }
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
            do {
                let e = try MiniLMEmbedder()
                try? await e.prewarm(batchSize: 1)
                return e
            } catch { return nil }
            #else
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
