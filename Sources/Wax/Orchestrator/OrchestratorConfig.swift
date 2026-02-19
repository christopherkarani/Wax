import Foundation
import WaxVectorSearch

public struct OrchestratorConfig: Sendable {
    public var enableTextSearch: Bool = true
    public var enableVectorSearch: Bool = true
    public var enableStructuredMemory: Bool = false
    public var enableAccessStatsScoring: Bool = false

    public var rag: FastRAGConfig = .init()
    public var chunking: ChunkingStrategy = .tokenCount(targetTokens: 400, overlapTokens: 40)
    public var ingestConcurrency: Int = 1
    public var ingestBatchSize: Int = 32
    public var embeddingCacheCapacity: Int = 2_048
    /// Prefer Metal-backed vector search when available.
    ///
    /// The actual engine selection still checks `MetalVectorEngine.isAvailable` at runtime.
    /// This avoids doing Metal device discovery during static initialization.
    public var useMetalVectorSearch: Bool = true

    /// When true, rejects text embedding providers that report `executionMode == .mayUseNetwork`.
    public var requireOnDeviceProviders: Bool = true
    public var liveSetRewriteSchedule: LiveSetRewriteSchedule = .disabled

    public init() {}

    public static let `default` = OrchestratorConfig()
}
