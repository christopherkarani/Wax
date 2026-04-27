#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import Foundation
import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
package extension MemoryOrchestrator {
    static func openMiniLM(
        at url: URL,
        config: OrchestratorConfig = .default
    ) async throws -> MemoryOrchestrator {
        let embedder = try MiniLMEmbedder()
        try await embedder.prewarm()
        return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    }

    static func openMiniLM(
        at url: URL,
        config: OrchestratorConfig = .default,
        overrides: MiniLMEmbeddings.Overrides
    ) async throws -> MemoryOrchestrator {
        let embedder = try MiniLMEmbedder(overrides: overrides)
        try await embedder.prewarm()
        return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    }
}
#endif
