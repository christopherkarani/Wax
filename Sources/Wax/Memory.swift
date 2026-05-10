import Foundation

/// Intuitive high-level facade for Wax memory operations.
public actor Memory {
    public struct Config: Sendable, Equatable {
        public var enableTextSearch: Bool
        public var enableVectorSearch: Bool
        public var enableStructuredMemory: Bool
        public var enableAccessStatsScoring: Bool
        public var enableAsyncEnrichment: Bool
        public var ingestConcurrency: Int
        public var ingestBatchSize: Int
        public var requireOnDeviceProviders: Bool

        public init(
            enableTextSearch: Bool = true,
            enableVectorSearch: Bool = true,
            enableStructuredMemory: Bool = false,
            enableAccessStatsScoring: Bool = false,
            enableAsyncEnrichment: Bool = false,
            ingestConcurrency: Int = 1,
            ingestBatchSize: Int = 32,
            requireOnDeviceProviders: Bool = true
        ) {
            self.enableTextSearch = enableTextSearch
            self.enableVectorSearch = enableVectorSearch
            self.enableStructuredMemory = enableStructuredMemory
            self.enableAccessStatsScoring = enableAccessStatsScoring
            self.enableAsyncEnrichment = enableAsyncEnrichment
            self.ingestConcurrency = ingestConcurrency
            self.ingestBatchSize = ingestBatchSize
            self.requireOnDeviceProviders = requireOnDeviceProviders
        }

        public static let `default` = Config()
    }

    public enum EmbeddingPolicy: Sendable, Equatable {
        case automatic
        case always
        case never
    }

    public struct TimeRange: Sendable, Equatable {
        public var afterMs: Int64?
        public var beforeMs: Int64?

        public init(afterMs: Int64? = nil, beforeMs: Int64? = nil) {
            self.afterMs = afterMs
            self.beforeMs = beforeMs
        }
    }

    public enum RetrievalMode: Sendable, Equatable {
        /// Search only the full-text index.
        case textOnly
        /// Search only the vector index. Requires vector search and an embedding provider.
        case vectorOnly
        /// Blend full-text and vector results using Reciprocal Rank Fusion.
        ///
        /// The alpha value is clamped by Wax's search engine. Higher values favor
        /// text results; lower values favor vector results.
        case hybrid(alpha: Float = 0.5)
    }

    public struct SearchOptions: Sendable, Equatable {
        public var topK: Int
        public var includeSurrogates: Bool
        public var timeRange: TimeRange?
        public var mode: RetrievalMode

        public init(
            topK: Int = 10,
            includeSurrogates: Bool = false,
            timeRange: TimeRange? = nil,
            mode: RetrievalMode = .hybrid()
        ) {
            self.topK = topK
            self.includeSurrogates = includeSurrogates
            self.timeRange = timeRange
            self.mode = mode
        }

        public static let `default` = SearchOptions()
    }

    public typealias Results = RAGContext
    public typealias Error = WaxError

    private let orchestrator: MemoryOrchestrator

    public init(at url: URL, config: Config = .default) async throws {
        self.orchestrator = try await MemoryOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config)
        )
    }

    public init(at url: URL, configure: (inout Config) -> Void) async throws {
        var config = Config.default
        configure(&config)
        self.orchestrator = try await MemoryOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config)
        )
    }

    public init(
        at url: URL,
        config: Config = .default,
        embedding: some EmbeddingProvider
    ) async throws {
        self.orchestrator = try await MemoryOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config),
            embedder: embedding
        )
    }

    public init(
        at url: URL,
        embedding: some EmbeddingProvider,
        configure: (inout Config) -> Void
    ) async throws {
        var config = Config.default
        configure(&config)
        self.orchestrator = try await MemoryOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config),
            embedder: embedding
        )
    }

    /// Open memory with one of Wax's built-in embedding providers.
    public init(
        at url: URL,
        config: Config = .default,
        builtInEmbedding provider: BuiltInEmbeddingProvider,
        embeddingOptions: BuiltInEmbeddingProviderOptions = .default
    ) async throws {
        let embedding = try await BuiltInEmbeddings.make(provider, options: embeddingOptions)
        self.orchestrator = try await MemoryOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config),
            embedder: embedding
        )
    }

    /// Persist text into memory.
    public func save(_ text: String, metadata: [String: String] = [:]) async throws {
        try await orchestrator.remember(text, metadata: metadata)
    }

    /// Persist multiple texts in a single call.
    public func save<each S: StringProtocol>(_ texts: repeat each S) async throws {
        repeat try await orchestrator.remember(String(each texts))
    }

    /// Search memory and return ranked context.
    public func search(_ query: String, options: SearchOptions = .default) async throws -> Results {
        let frameFilter = FrameFilter(includeSurrogates: options.includeSurrogates)
        let mappedTimeRange = options.timeRange.map { SearchTimeRange(after: $0.afterMs, before: $0.beforeMs) }
        let directMode: MemoryOrchestrator.DirectSearchMode = switch options.mode {
        case .textOnly:
            .text
        case .vectorOnly:
            .vector
        case .hybrid(let alpha):
            .hybrid(alpha: alpha)
        }
        let embeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy = switch options.mode {
        case .textOnly:
            .never
        case .vectorOnly:
            .always
        case .hybrid:
            .ifAvailable
        }

        return try await orchestrator.recall(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: frameFilter,
            timeRange: mappedTimeRange,
            topK: options.topK,
            mode: directMode
        )
    }

    /// Search with inline option customization.
    public func search(_ query: String, configure: (inout SearchOptions) -> Void) async throws -> Results {
        var options = SearchOptions.default
        configure(&options)
        return try await search(query, options: options)
    }

    public func search<S: SearchStrategy>(
        _ query: String,
        strategy: S,
        options: SearchOptions = .default
    ) async throws -> Results {
        var resolved = options
        strategy.configure(&resolved)
        return try await search(query, options: resolved)
    }

    public func search<S: SearchStrategy, R: ResultReranker>(
        _ query: String,
        strategy: S,
        options: SearchOptions = .default,
        reranker: R
    ) async throws -> Results {
        let results = try await search(query, strategy: strategy, options: options)
        return try await reranker.rerank(query: query, results: results)
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Close the memory handle and release resources.
    public func close() async throws {
        try await orchestrator.close()
    }

    private static func makeOrchestratorConfig(_ config: Config) -> OrchestratorConfig {
        var resolved = OrchestratorConfig.default
        resolved.enableTextSearch = config.enableTextSearch
        resolved.enableVectorSearch = config.enableVectorSearch
        resolved.enableStructuredMemory = config.enableStructuredMemory
        resolved.enableAccessStatsScoring = config.enableAccessStatsScoring
        resolved.enableAsyncEnrichment = config.enableAsyncEnrichment
        resolved.ingestConcurrency = config.ingestConcurrency
        resolved.ingestBatchSize = config.ingestBatchSize
        resolved.requireOnDeviceProviders = config.requireOnDeviceProviders
        return resolved
    }
}

public protocol SearchStrategy: Sendable {
    func configure(_ options: inout Memory.SearchOptions)
}

public protocol ResultReranker: Sendable {
    func rerank(query: String, results: Memory.Results) async throws -> Memory.Results
}
