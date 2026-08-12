import Foundation
import WaxCore

/// Intuitive high-level facade for Wax memory operations.
public actor Memory {
    public struct Config: Sendable {
        public var enableTextSearch: Bool
        public var enableVectorSearch: Bool
        /// Enables entity, fact, and edge APIs on ``Memory``.
        ///
        /// When false, ``upsertEntity(key:kind:aliases:)``, ``resolveEntities(alias:limit:)``,
        /// ``assertFact(subject:predicate:object:relation:validFromMs:validToMs:)``,
        /// ``retractFact(_:atMs:)``, ``facts(subject:predicate:systemAsOfMs:validAsOfMs:limit:)``,
        /// and ``edges(for:direction:predicate:systemAsOfMs:validAsOfMs:limit:)`` throw
        /// ``WaxError/featureDisabled(feature:)`` with `feature` `"structured memory"`.
        public var enableStructuredMemory: Bool
        public var enableAccessStatsScoring: Bool
        /// Built-in keyword/entity enrichment. ``EnrichmentPolicy/disabled`` (the
        /// default) leaves ``Stats-swift.struct/enrichment`` `nil`.
        public var enrichment: EnrichmentPolicy
        /// Bounded FastRAG knobs (context budget, search depth, answer rerank).
        ///
        /// Out-of-range values are clamped once while mapping into the package
        /// FastRAG builder; they do not throw ``WaxError/invalidConfiguration(reason:)``.
        public var rag: RAGConfig
        public var ingestConcurrency: Int
        public var ingestBatchSize: Int
        public var requireOnDeviceProviders: Bool
        /// Which embedding provider backs vector search.
        public var embedding: EmbeddingSource
        /// WAL region size used when creating a new store. Existing files keep the
        /// size recorded in their header.
        public static let defaultWalSizeBytes: UInt64 = 4 * 1024 * 1024
        public var walSizeBytes: UInt64

        public init(
            enableTextSearch: Bool = true,
            enableVectorSearch: Bool = true,
            enableStructuredMemory: Bool = false,
            enableAccessStatsScoring: Bool = false,
            enrichment: EnrichmentPolicy = .disabled,
            rag: RAGConfig = .default,
            ingestConcurrency: Int = 1,
            ingestBatchSize: Int = 32,
            requireOnDeviceProviders: Bool = true,
            embedding: EmbeddingSource = .automatic,
            walSizeBytes: UInt64 = Config.defaultWalSizeBytes
        ) {
            self.enableTextSearch = enableTextSearch
            self.enableVectorSearch = enableVectorSearch
            self.enableStructuredMemory = enableStructuredMemory
            self.enableAccessStatsScoring = enableAccessStatsScoring
            self.enrichment = enrichment
            self.rag = rag
            self.ingestConcurrency = ingestConcurrency
            self.ingestBatchSize = ingestBatchSize
            self.requireOnDeviceProviders = requireOnDeviceProviders
            self.embedding = embedding
            self.walSizeBytes = walSizeBytes
        }

        public static let `default` = Config()
    }

    /// Selects the embedding provider that backs vector search for a ``Memory`` store.
    public enum EmbeddingSource: Sendable {
        /// Wire the built-in MiniLM embedder automatically on iOS 18/macOS 15+ when Wax
        /// is built with the default `MiniLMEmbeddings` trait. On older OS versions, or
        /// if the model is unavailable, the store falls back to text-only search;
        /// inspect ``RAGContext/diagnostics`` on search results or ``Memory/stats()``
        /// to see which mode is actually in effect.
        case automatic
        /// Use one of Wax's built-in embedding providers. Store creation throws if the
        /// provider cannot be constructed (trait compiled out, model missing, or
        /// unsupported OS).
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

    package let orchestrator: MemoryOrchestrator
    private let embeddingStatusOverride: EmbeddingStatus?

    /// Package-visible wrap of an existing orchestrator for in-module adapters.
    package init(orchestrator: MemoryOrchestrator) {
        self.orchestrator = orchestrator
        self.embeddingStatusOverride = nil
    }

    /// Create or open a memory store at the given URL.
    ///
    /// Embedder selection lives on ``Config/embedding`` and defaults to
    /// ``EmbeddingSource/automatic``: the built-in MiniLM embedder is wired on
    /// iOS 18/macOS 15+ when Wax is built with the default `MiniLMEmbeddings` trait.
    /// On older OS versions, or if the model is unavailable, the store falls back to
    /// text-only search; inspect ``RAGContext/diagnostics`` on search results or
    /// ``stats()`` to see which mode is actually in effect.
    public init(at url: URL, config: Config = .default) async throws {
        try Self.validate(config)
        let setup = try await Self.resolveEmbedder(for: config)
        self.embeddingStatusOverride = setup.status
        self.orchestrator = try await MemoryOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config),
            embedder: setup.embedder
        )
    }

    /// Create or open a memory store at the given URL with inline configuration.
    ///
    /// The same embedder selection as ``init(at:config:)`` applies; set
    /// ``Config/embedding`` inside the closure to use a built-in or custom provider.
    public init(at url: URL, configure: @Sendable (inout Config) -> Void) async throws {
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

        let execution = try await orchestrator.recallExecution(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: frameFilter,
            timeRange: mappedTimeRange,
            topK: nil,
            mode: directMode
        )
        var results = Self.limiting(execution.context, toTopK: options.topK)
        results.diagnostics = RAGContext.Diagnostics(
            requestedMode: execution.requestedModeSummary,
            effectiveMode: execution.effectiveModeSummary,
            queryEmbeddingState: RAGContext.QueryEmbeddingState(execution.queryEmbeddingState)
        )
        return results
    }

    /// Search with inline option customization.
    public func search(_ query: String, configure: @Sendable (inout SearchOptions) -> Void) async throws -> Results {
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
    ///
    /// When enrichment is enabled, this waits for the pipeline to drain. After a
    /// successful return, ``Stats-swift.struct/enrichment`` pending count is zero;
    /// if the drain times out, this throws.
    public func flush() async throws {
        try await orchestrator.flush(requireEnrichmentDrain: true)
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
        /// Embedding setup recorded at store initialization.
        public var embeddingStatus: EmbeddingStatus
        /// Enrichment pipeline snapshot when ``Config-swift.struct/enrichment`` is
        /// ``EnrichmentPolicy/builtIn``; `nil` when enrichment is disabled.
        public var enrichment: EnrichmentStats?

        public init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            vectorSearchEnabled: Bool,
            queryEmbedderConfigured: Bool,
            queryEmbeddingCircuitOpen: Bool,
            embedderIdentity: EmbeddingIdentity?,
            embeddingStatus: EmbeddingStatus = .disabled,
            enrichment: EnrichmentStats? = nil
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.vectorSearchEnabled = vectorSearchEnabled
            self.queryEmbedderConfigured = queryEmbedderConfigured
            self.queryEmbeddingCircuitOpen = queryEmbeddingCircuitOpen
            self.embedderIdentity = embedderIdentity
            self.embeddingStatus = embeddingStatus
            self.enrichment = enrichment
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
            queryEmbedderConfigured: runtime.queryEmbedderConfigured,
            queryEmbeddingCircuitOpen: runtime.queryEmbeddingCircuitOpen,
            embedderIdentity: runtime.embedderIdentity,
            embeddingStatus: embeddingStatusOverride ?? Self.inferredEmbeddingStatus(from: runtime),
            enrichment: runtime.enrichment.map {
                EnrichmentStats(
                    processedCount: $0.processedCount,
                    pendingCount: $0.pendingCount,
                    isRunning: $0.isRunning
                )
            }
        )
    }

    /// Internal result of ``EmbeddingSource/automatic`` resolution.
    private enum AutoEmbedderResolution: Sendable {
        case resolved(any EmbeddingProvider)
        case unavailable(reason: String)
        case disabled
    }

    private struct EmbedderSetup: Sendable {
        var embedder: (any EmbeddingProvider)?
        var status: EmbeddingStatus
    }

    /// Resolves the embedder for ``Config/embedding``. `.automatic` returns nil
    /// (text-only fallback) on unsupported OS versions, when the `MiniLMEmbeddings`
    /// trait is compiled out, or when the model fails to load; `.builtIn` throws
    /// instead of falling back so misconfiguration surfaces immediately.
    private static func resolveEmbedder(for config: Config) async throws -> EmbedderSetup {
        switch config.embedding {
        case .automatic:
            switch await resolveAutomatic(config: config) {
            case .resolved(let provider):
                return EmbedderSetup(
                    embedder: provider,
                    status: .active(identity: provider.identity)
                )
            case .unavailable(let reason):
                return EmbedderSetup(
                    embedder: nil,
                    status: .unavailable(reason: reason)
                )
            case .disabled:
                return EmbedderSetup(embedder: nil, status: .disabled)
            }
        case .builtIn(let provider, let options):
            let embedder = try await BuiltInEmbeddings.make(provider, options: options)
            return EmbedderSetup(
                embedder: embedder,
                status: config.enableVectorSearch
                    ? .active(identity: embedder.identity)
                    : .disabled
            )
        case .custom(let provider):
            return EmbedderSetup(
                embedder: provider,
                status: config.enableVectorSearch
                    ? .active(identity: provider.identity)
                    : .disabled
            )
        }
    }

    private static func resolveAutomatic(config: Config) async -> AutoEmbedderResolution {
        guard config.enableVectorSearch else { return .disabled }
        do {
            let embedder = try await BuiltInEmbeddings.make(.miniLM, options: .automatic)
            return .resolved(embedder)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    private static func inferredEmbeddingStatus(
        from runtime: MemoryOrchestrator.RuntimeStats
    ) -> EmbeddingStatus {
        if !runtime.vectorSearchEnabled {
            return .disabled
        }
        if runtime.queryEmbedderConfigured {
            return .active(identity: runtime.embedderIdentity)
        }
        return .unavailable(reason: "embedding provider is not configured")
    }

    private static func validate(_ config: Config) throws {
        guard config.walSizeBytes >= Constants.walRecordHeaderSize else {
            throw WaxError.invalidConfiguration(
                reason: "WAL size must be at least \(Constants.walRecordHeaderSize) bytes (WAL record header); got \(config.walSizeBytes)"
            )
        }
    }

    private static func makeOrchestratorConfig(_ config: Config) -> OrchestratorConfig {
        OrchestratorConfig.resolving(config)
    }

    private static func limiting(_ context: RAGContext, toTopK topK: Int) -> RAGContext {
        if topK <= 0 {
            return RAGContext(query: context.query, items: [], totalTokens: 0)
        }
        guard context.items.count > topK else { return context }
        return RAGContext(
            query: context.query,
            items: Array(context.items.prefix(topK)),
            totalTokens: context.totalTokens
        )
    }
}

public protocol SearchStrategy: Sendable {
    func configure(_ options: inout Memory.SearchOptions)
}

public protocol ResultReranker: Sendable {
    func rerank(query: String, results: Memory.Results) async throws -> Memory.Results
}
