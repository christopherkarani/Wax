import Foundation
import Wax

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
