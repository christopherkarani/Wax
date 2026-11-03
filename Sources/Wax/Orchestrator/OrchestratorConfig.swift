import Foundation
import WaxVectorSearch

package struct OrchestratorConfig: Sendable {
    package var enableTextSearch: Bool = true
    package var enableVectorSearch: Bool = true
    package var enableStructuredMemory: Bool = false
    package var enableAccessStatsScoring: Bool = true
    package var enableAsyncEnrichment: Bool = false

    package var rag: FastRAGConfig = .init()
    package static let defaultChunking = ChunkingStrategy.tokenCount(targetTokens: 400, overlapTokens: 40)
    package var chunking: ChunkingStrategy = defaultChunking
    /// Re-split chunks that overflow the MiniLM input window. Set by ``sizingChunks(forEmbedderModel:)``.
    package var fitsChunksToMiniLMInput: Bool = false
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
    /// Start re-embedding vectors written by a superseded model revision as soon as the
    /// embedder is ready. Read-only hosts (CLI recall/search/stats) turn this off and
    /// re-embed only through an explicit ``MemoryOrchestrator/backfillUnembedded()``.
    package var automaticallyReembedSupersededVectors: Bool = true
    /// On open, index durable frames the text index does not cover yet; the next commit
    /// persists them. Off by default so brief opens (corpus, ended-session, migration
    /// verification, direct-store CLI) never write. The store's owning writer turns it on:
    /// the broker's long-term and live session stores, and the library's `Memory`.
    package var catchUpTextIndexOnOpen: Bool = false
    /// Frames re-embedded between durable progress checkpoints. `nil` picks
    /// max(512, frames / 16), which bounds the number of full commits per re-embed.
    package var supersededReembedCheckpointFrames: Int? = nil
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
