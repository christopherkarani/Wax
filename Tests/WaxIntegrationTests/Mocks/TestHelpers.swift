import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch

enum TestHelpers {
    static func defaultMemoryConfig(vector: Bool = true) -> OrchestratorConfig {
        var config = OrchestratorConfig.default
        config.enableVectorSearch = vector
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 0)
        config.ingestBatchSize = 4
        config.ingestConcurrency = 1
        return config
    }
}

extension Wax {
    /// Test search through an owner-scoped ``UnifiedSearchEngineStore`` — there is
    /// no process-global engine cache anymore. Without an explicit `engineStore`
    /// a fresh ephemeral store scopes engine lifetime to the call; pass one to
    /// keep engines warm across searches (benchmarks, reuse assertions).
    /// `engines` supplies explicit engines (e.g. test fakes) that take precedence
    /// over the store per lane.
    func searchWithEngineStore(
        _ request: SearchRequest,
        engines: UnifiedSearchEngines? = nil,
        engineStore: UnifiedSearchEngineStore? = nil
    ) async throws -> SearchResponse {
        try await search(request, engines: engines, engineStore: engineStore ?? UnifiedSearchEngineStore())
    }
}
