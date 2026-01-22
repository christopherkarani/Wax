import Foundation

public struct OrchestratorConfig: Sendable {
    public var enableTextSearch: Bool = true
    public var enableVectorSearch: Bool = true

    public var rag: FastRAGConfig = .init()
    public var chunking: ChunkingStrategy = .tokenCount(targetTokens: 400, overlapTokens: 40)
    public var ingestConcurrency: Int = 1
    public var ingestBatchSize: Int = 32
    public var embeddingCacheCapacity: Int = 2_048

    public init() {}

    public static let `default` = OrchestratorConfig()
}
