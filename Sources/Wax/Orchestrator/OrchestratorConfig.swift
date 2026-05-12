import Foundation
import WaxVectorSearch

package struct OrchestratorConfig: Sendable {
    package var enableTextSearch: Bool = true
    package var enableVectorSearch: Bool = true
    package var enableStructuredMemory: Bool = false
    package var enableAccessStatsScoring: Bool = false
    package var enableAsyncEnrichment: Bool = false

    package var rag: FastRAGConfig = .init()
    package var chunking: ChunkingStrategy = .tokenCount(targetTokens: 400, overlapTokens: 40)
    package var ingestConcurrency: Int = 1
    package var ingestBatchSize: Int = 32
    package var embeddingCacheCapacity: Int = 2_048
    package var enrichmentFlushDrainTimeout: Duration = .seconds(30)
    package var enrichmentStopTimeout: Duration = .seconds(10)
    package var vectorEnginePreference: VectorEnginePreference = .auto
    package var queryEmbeddingTimeout: Duration? = .seconds(10)
    package var ingestEmbeddingTimeout: Duration? = .seconds(30)
    package var vectorSearchTimeout: Duration? = .seconds(10)

    package var requireOnDeviceProviders: Bool = true
    package var liveSetRewriteSchedule: LiveSetRewriteSchedule = .conservativeAutomatic
    package var defaultScopeContext: MemoryScopeContext? = nil

    @available(*, deprecated, message: "Use vectorEnginePreference instead")
    package var useMetalVectorSearch: Bool {
        get { vectorEnginePreference != .cpuOnly }
        set { vectorEnginePreference = newValue ? .auto : .cpuOnly }
    }

    package init() {}

    package static let `default` = OrchestratorConfig()
}
