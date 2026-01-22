#if canImport(WaxVectorSearchMiniLM)
import Foundation
import WaxVectorSearchMiniLM

public extension MemoryOrchestrator {
    static func openMiniLM(
        at url: URL,
        config: OrchestratorConfig = .default
    ) async throws -> MemoryOrchestrator {
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: MiniLMEmbedder())
        Task.detached(priority: .utility) {
            await WaxPrewarm.miniLM()
        }
        return orchestrator
    }
}
#endif

