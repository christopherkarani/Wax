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

/// Injectable orchestrator clock so tests advance time without sleeping.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) {
        value = start
    }

    var nowMs: Int64 {
        get { lock.withLock { value } }
    }

    func advance(ms: Int64) {
        lock.withLock { value += ms }
    }
}
