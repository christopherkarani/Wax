import Foundation

/// Intuitive high-level facade for Wax memory operations.
public actor Memory {
    public struct Config: Sendable {
        public var enableTextSearch: Bool
        public var enableVectorSearch: Bool
        public var enableStructuredMemory: Bool
        public var enableAccessStatsScoring: Bool
        public var enableAsyncEnrichment: Bool
        public var ingestConcurrency: Int
        public var ingestBatchSize: Int
        public var requireOnDeviceProviders: Bool
        /// Which embedding provider backs vector search.
        public var embedding: EmbeddingSource

        public init(
            enableTextSearch: Bool = true,
            enableVectorSearch: Bool = true,
            enableStructuredMemory: Bool = false,
            enableAccessStatsScoring: Bool = false,
            enableAsyncEnrichment: Bool = false,
            ingestConcurrency: Int = 1,
            ingestBatchSize: Int = 32,
            requireOnDeviceProviders: Bool = true,
            embedding: EmbeddingSource = .automatic
        ) {
            self.enableTextSearch = enableTextSearch
            self.enableVectorSearch = enableVectorSearch
            self.enableStructuredMemory = enableStructuredMemory
            self.enableAccessStatsScoring = enableAccessStatsScoring
            self.enableAsyncEnrichment = enableAsyncEnrichment
            self.ingestConcurrency = ingestConcurrency
            self.ingestBatchSize = ingestBatchSize
            self.requireOnDeviceProviders = requireOnDeviceProviders
            self.embedding = embedding
        }

        public static let `default` = Config()
    }

    /// Selects the embedding provider that backs vector search for a ``Memory`` store.
    public enum EmbeddingSource: Sendable {
        /// Prefer a built-in provider but open immediately while it loads.
        /// Hybrid search is text until compile finishes and this store live-attaches;
        /// ``vectorOnly`` throws until then. If the provider cannot activate, status is
        /// ``EmbeddingStatus/unavailable`` (the vector index remains). Inspect
        /// ``RAGContext/diagnostics`` or ``Memory/stats()``.
        case automatic
        /// Use one of Wax's built-in embedding providers. Store creation throws if the
        /// provider cannot be constructed (trait compiled out, model missing,
        /// unsupported OS) or if compile exceeds the wait timeout.
        case builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions = .default)
        /// Use a custom embedding provider.
        case custom(any EmbeddingProvider)
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

    /// Package-visible wrap of an existing orchestrator for in-module adapters.
    package init(orchestrator: MemoryOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// Create or open a memory store at the given URL.
    ///
    /// Embedder selection lives on ``Config/embedding`` and defaults to
    /// ``EmbeddingSource/automatic``: the store opens while the built-in provider
    /// loads, then live-attaches. Inspect ``RAGContext/diagnostics`` or ``stats()``.
    public init(at url: URL, config: Config = .default) async throws {
        try await self.init(at: url, config: config, readiness: .shared, readinessFactory: nil)
    }

    /// Package test seam: inject readiness and a compile factory.
    package init(
        at url: URL,
        config: Config,
        readiness: EmbeddingReadiness,
        readinessFactory: (@Sendable () async throws -> any EmbeddingProvider)?
    ) async throws {
        self.orchestrator = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config),
            request: Self.openRequest(for: config),
            readiness: readiness,
            factoryOverride: readinessFactory
        )
    }

    /// Create or open a memory store at the given URL with inline configuration.
    ///
    /// The same embedder selection as ``init(at:config:)`` applies; set
    /// ``Config/embedding`` inside the closure to use a built-in or custom provider.
    public init(at url: URL, configure: (inout Config) -> Void) async throws {
        var config = Config.default
        configure(&config)
        try await self.init(at: url, config: config)
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
        let execution = try await orchestrator.recallExecution(
            query: query,
            mode: options.mode,
            frameFilter: frameFilter,
            timeRange: mappedTimeRange,
            topK: options.topK
        )
        var results = execution.context
        results.diagnostics = RAGContext.Diagnostics(
            requestedMode: execution.requestedModeSummary,
            effectiveMode: execution.effectiveModeSummary,
            queryEmbeddingState: RAGContext.QueryEmbeddingState(execution.queryEmbeddingState)
        )
        return results
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

    /// Soft-delete a memory frame and remove it from enabled search indexes.
    ///
    /// Used by forget tooling and callers that need to retract a specific frame ID
    /// returned from ``search(_:options:)``.
    public func delete(frameID: UInt64) async throws {
        try await orchestrator.delete(frameId: frameID)
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Close the memory handle and release resources.
    public func close() async throws {
        try await orchestrator.close()
    }

    /// Snapshot of memory health and retrieval configuration.
    public struct Stats: Sendable, Equatable {
        /// Total frames in the store.
        public var frameCount: UInt64
        /// Frames written but not yet committed to durable storage.
        public var pendingFrames: UInt64
        /// Whether the vector index is enabled for this store.
        public var vectorSearchEnabled: Bool
        /// Whether a query-time embedding provider is configured.
        public var queryEmbedderConfigured: Bool
        /// Whether query embedding is currently paused by the timeout circuit breaker.
        public var queryEmbeddingCircuitOpen: Bool
        /// Identity of the configured embedding provider, if any.
        public var embedderIdentity: EmbeddingIdentity?
        /// Readiness of the embedding provider attached to this store.
        public var embeddingStatus: EmbeddingStatus

        public init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            vectorSearchEnabled: Bool,
            queryEmbedderConfigured: Bool,
            queryEmbeddingCircuitOpen: Bool,
            embedderIdentity: EmbeddingIdentity?,
            embeddingStatus: EmbeddingStatus = .disabled
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.vectorSearchEnabled = vectorSearchEnabled
            self.queryEmbedderConfigured = queryEmbedderConfigured
            self.queryEmbeddingCircuitOpen = queryEmbeddingCircuitOpen
            self.embedderIdentity = embedderIdentity
            self.embeddingStatus = embeddingStatus
        }
    }

    /// Health snapshot: store counts, vector status, and query-embedding circuit state.
    ///
    /// Use this to verify that semantic search is actually active — for example after
    /// opening a store on a platform where the built-in embedder is unavailable.
    public func stats() async -> Stats {
        let runtime = await orchestrator.runtimeStats()
        return Stats(
            frameCount: runtime.frameCount,
            pendingFrames: runtime.pendingFrames,
            vectorSearchEnabled: runtime.vectorSearchEnabled,
            queryEmbedderConfigured: EmbeddingStatus.queryEmbedderConfigured(runtime.embeddingStatus),
            queryEmbeddingCircuitOpen: runtime.queryEmbeddingCircuitOpen,
            embedderIdentity: runtime.embeddingStatus.identity,
            embeddingStatus: runtime.embeddingStatus
        )
    }

    package func setSearchSnapshotHoldForTesting(_ duration: Duration?) async {
        await orchestrator.setSearchSnapshotHoldForTesting(duration)
    }

    private static func openRequest(for config: Config) -> EmbeddingOpenRequest {
        guard config.enableVectorSearch else { return .disabled }
        switch config.embedding {
        case .automatic:
            return .automatic(.miniLM, .default)
        case .builtIn(let provider, let options):
            return .builtIn(provider, options)
        case .custom(let provider):
            return .custom(provider)
        }
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
