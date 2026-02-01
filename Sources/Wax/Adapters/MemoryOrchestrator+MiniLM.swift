#if canImport(WaxVectorSearchMiniLM)
import Foundation
import WaxVectorSearchMiniLM

public extension MemoryOrchestrator {
    static func openMiniLM(
        at url: URL,
        config: OrchestratorConfig = .default
    ) async throws -> MemoryOrchestrator {
        let embedder = MiniLMEmbedder()
        _ = try? await embedder.prewarm()
        return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    }
}
#endif
