#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import Foundation
import WaxVectorSearchArctic

@available(macOS 15.0, iOS 18.0, *)
package extension MemoryOrchestrator {
    static func openArctic(
        at url: URL,
        config: OrchestratorConfig = .default
    ) async throws -> MemoryOrchestrator {
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm()
        return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    }

    static func openArctic(
        at url: URL,
        config: OrchestratorConfig = .default,
        overrides: ArcticEmbeddings.Overrides
    ) async throws -> MemoryOrchestrator {
        let embedder = try ArcticEmbedder(overrides: overrides)
        try await embedder.prewarm()
        return try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    }
}
#endif
