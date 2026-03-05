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
    /// Best-effort wait budget for draining async enrichment during `flush()`.
    /// When exceeded, flush proceeds and logs a diagnostic.
    package var enrichmentFlushDrainTimeout: Duration = .seconds(30)
    /// Maximum wait for stopping async enrichment during `close()`.
    /// When exceeded, close continues and logs a diagnostic.
    package var enrichmentStopTimeout: Duration = .seconds(10)
    /// Prefer Metal-backed vector search when available.
    ///
    /// The actual engine selection still checks `MetalVectorEngine.isAvailable` at runtime.
    /// This avoids doing Metal device discovery during static initialization.
    package var useMetalVectorSearch: Bool = true
    /// Best-effort timeout for computing a query embedding during recall/search.
    /// When exceeded, Wax falls back to text-only retrieval for that query (when allowed).
    package var queryEmbeddingTimeout: Duration? = .seconds(10)
    /// Best-effort timeout for vector-engine search during unified search.
    /// When exceeded, Wax falls back to non-vector lanes when possible.
    package var vectorSearchTimeout: Duration? = .seconds(10)

    /// When true, rejects text embedding providers that report `executionMode == .mayUseNetwork`.
    package var requireOnDeviceProviders: Bool = true
    package var liveSetRewriteSchedule: LiveSetRewriteSchedule = .disabled

    package init() {}

    package static let `default` = OrchestratorConfig()
}
