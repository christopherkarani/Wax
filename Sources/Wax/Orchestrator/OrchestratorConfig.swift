import Foundation
import WaxCore
import WaxVectorSearch

package struct OrchestratorConfig: Sendable {
    package var enableTextSearch: Bool = true
    package var enableVectorSearch: Bool = true
    package var enableStructuredMemory: Bool = false
    package var enableAccessStatsScoring: Bool = false
    /// Package equivalent of ``Memory/EnrichmentPolicy/builtIn``.
    package var enableAsyncEnrichment: Bool = false

    /// FastRAG builder config. Public ``Memory/RAGConfig`` is clamped into this once.
    package var rag: FastRAGConfig = .init()
    package var chunking: ChunkingStrategy = .tokenCount(targetTokens: 400, overlapTokens: 40)
    package var ingestConcurrency: Int = 1
    package var ingestBatchSize: Int = 32
    package var embeddingCacheCapacity: Int = 2_048
    package var enrichmentFlushDrainTimeout: Duration = .seconds(30)
    package var enrichmentStopTimeout: Duration = .seconds(10)
    package var vectorEnginePreference: VectorEnginePreference = .auto
    package var queryEmbeddingTimeout: Duration? = .seconds(10)
    /// How long query embedding stays disabled after a timeout before a half-open retry.
    /// A successful retry closes the circuit; another timeout re-opens it.
    package var queryEmbeddingCircuitCooldown: Duration = .seconds(60)
    /// Cold MiniLM/Arctic CoreML loads can exceed 30s; keep headroom for first ingest.
    package var ingestEmbeddingTimeout: Duration? = .seconds(120)
    package var vectorSearchTimeout: Duration? = .seconds(10)

    package var requireOnDeviceProviders: Bool = true
    package var liveSetRewriteSchedule: LiveSetRewriteSchedule = .conservativeAutomatic
    package var defaultScopeContext: MemoryScopeContext? = nil
    /// WAL region size used when creating a missing store file. Existing files
    /// keep the size recorded in their header.
    package var walSizeBytes: UInt64 = Constants.publicFacadeWalSize

    @available(*, deprecated, message: "Use vectorEnginePreference instead")
    package var useMetalVectorSearch: Bool {
        get { vectorEnginePreference != .cpuOnly }
        set { vectorEnginePreference = newValue ? .auto : .cpuOnly }
    }

    package init() {}

    package static let `default` = OrchestratorConfig()

    /// Map public ``Memory/Config-swift.struct`` onto package orchestrator knobs.
    /// RAG fields are clamped here exactly once into ``FastRAGConfig``.
    package static func resolving(_ config: Memory.Config) -> OrchestratorConfig {
        var resolved = OrchestratorConfig.default
        resolved.enableTextSearch = config.enableTextSearch
        resolved.enableVectorSearch = config.enableVectorSearch
        resolved.enableStructuredMemory = config.enableStructuredMemory
        resolved.enableAccessStatsScoring = config.enableAccessStatsScoring
        resolved.enableAsyncEnrichment = config.enrichment == .builtIn
        resolved.rag = config.rag.makeFastRAGConfig()
        resolved.ingestConcurrency = config.ingestConcurrency
        resolved.ingestBatchSize = config.ingestBatchSize
        resolved.requireOnDeviceProviders = config.requireOnDeviceProviders
        resolved.walSizeBytes = config.walSizeBytes
        return resolved
    }
}
