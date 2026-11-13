import Foundation

/// Intuitive high-level facade for Wax memory operations.
public actor Memory {
    public struct Config: Sendable {
        public var enableTextSearch: Bool
        public var enableVectorSearch: Bool
        public var enableStructuredMemory: Bool
        /// When true (default), retrieval ranking applies a bounded offset from
        /// stored access stats. Search and recall do not record access; stats
        /// accrue from explicit get/promote. Access stats persist as a system
        /// frame, not a user-visible content frame.
        public var enableAccessStatsScoring: Bool
        public var enableAsyncEnrichment: Bool
        public var ingestConcurrency: Int
        public var ingestBatchSize: Int
        public var requireOnDeviceProviders: Bool
        /// Which embedding provider backs vector search.
        public var embedding: EmbeddingSource
        /// Which reranker, if any, reorders each search's top candidates. Defaults to
        /// ``RerankingSource/disabled``.
        public var reranking: RerankingSource

        public init(
            enableTextSearch: Bool = true,
            enableVectorSearch: Bool = true,
            enableStructuredMemory: Bool = false,
            enableAccessStatsScoring: Bool = true,
            enableAsyncEnrichment: Bool = false,
            ingestConcurrency: Int = 1,
            ingestBatchSize: Int = 32,
            requireOnDeviceProviders: Bool = true,
            embedding: EmbeddingSource = .automatic,
            reranking: RerankingSource = .disabled
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
            self.reranking = reranking
        }

        public static let `default` = Config()
    }

    /// Selects the embedding provider that backs vector search for a ``Memory`` store.
    public enum EmbeddingSource: Sendable {
        /// Prefer a built-in provider but open immediately while it loads.
        /// A new store gets e5 (`E5Embeddings` trait, on by default). An existing store
        /// keeps the built-in that wrote its vectors, so a MiniLM store stays on MiniLM.
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

    /// Retrieval lane used by the Foundation Models memory tools and session
    /// (`WaxMemoryToolConfig`, `WaxFoundationModelSession`): `.automatic` maps to
    /// hybrid search, `.always` to vector-only, `.never` to text-only.
    public enum EmbeddingPolicy: Sendable, Equatable {
        case automatic
        case always
        case never
    }

    /// Save-time window in milliseconds since 1970: `afterMs` inclusive, `beforeMs` exclusive.
    public struct TimeRange: Sendable, Equatable {
        public var afterMs: Int64?
        public var beforeMs: Int64?

        public init(afterMs: Int64? = nil, beforeMs: Int64? = nil) {
            self.afterMs = afterMs
            self.beforeMs = beforeMs
        }
    }

    /// Retrieval mode for `Memory.search` — text-only, vector-only, or hybrid.
    ///
    /// Aliases the package-wide canonical lane type `SearchMode`.
    public typealias RetrievalMode = SearchMode

    public struct SearchOptions: Sendable, Equatable {
        /// Bounds applied to ``maxContextTokens``.
        public static let maxContextTokensRange: ClosedRange<Int> = 64...32_768

        public var topK: Int
        public var includeSurrogates: Bool
        public var timeRange: TimeRange?
        /// Retrieval mode. Left unset, search is hybrid with the store's default text
        /// weight: 0.4 when the store's embedder is e5-small-v2, 0.5 otherwise. Reading an
        /// unset mode returns `.hybrid()`. A mode passed to the initializer or assigned here,
        /// `.hybrid()` included, is used exactly as given.
        public var mode: RetrievalMode {
            get { chosenMode ?? .hybrid() }
            set { chosenMode = newValue }
        }
        /// The caller's mode; `nil` leaves the hybrid text weight to the store.
        private var chosenMode: RetrievalMode?
        /// Token budget for the returned context. `nil` uses the store default
        /// (1,500 tokens). Clamped to ``maxContextTokensRange``. Raise it when a
        /// large ``topK`` returns fewer items than requested.
        public var maxContextTokens: Int?
        /// When `true` and ``timeRange`` is `nil`, a past-looking phrase in the
        /// query ("yesterday", "last week") filters results to memories saved in
        /// that window. Future-looking phrases ("tomorrow", "next week") never
        /// filter; a past phrase elsewhere in the same query still can. The
        /// applied window is reported in
        /// ``RAGContext/Diagnostics/inferredTimeRange``.
        public var inferTimeRange: Bool

        public init(
            topK: Int = 10,
            includeSurrogates: Bool = false,
            timeRange: TimeRange? = nil,
            mode: RetrievalMode? = nil,
            maxContextTokens: Int? = nil,
            inferTimeRange: Bool = true
        ) {
            self.topK = topK
            self.includeSurrogates = includeSurrogates
            self.timeRange = timeRange
            self.chosenMode = mode
            self.maxContextTokens = maxContextTokens
            self.inferTimeRange = inferTimeRange
        }

        public static let `default` = SearchOptions()

        /// The mode a store resolves: unset is hybrid at the store's default weight.
        package var modeRequest: SearchModeRequest {
            chosenMode.map(SearchModeRequest.init) ?? .hybrid(alpha: nil)
        }
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
    ///
    /// If another process holds the store file's lock, opening waits up to 30 seconds and
    /// then throws `WaxError.lockUnavailable`.
    ///
    /// `Memory` owns the store it opens. If the text index is missing frames (after a crash, or
    /// frames written without one), opening indexes them and ``close()`` commits that, so a
    /// store opened only to read can still be written once on close.
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
        let reranking = try await BuiltInRerankerCompiler.stage(for: config.reranking)
        self.orchestrator = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: Self.makeOrchestratorConfig(config, reranking: reranking),
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
    ///
    /// - Returns: The saved document's frame ID; pass it to ``delete(frameID:)``.
    ///   Saving identical text and metadata again returns the existing ID. Text
    ///   longer than one chunk is also indexed as chunk frames, whose IDs appear
    ///   in search results.
    @discardableResult
    public func save(_ text: String, metadata: [String: String] = [:]) async throws -> UInt64 {
        try await orchestrator.remember(text, metadata: metadata).frameId
    }

    /// Persist many texts that share one metadata dictionary, embedding and writing
    /// them in batches.
    ///
    /// - Returns: One frame ID per text, in input order: what calling
    ///   ``save(_:metadata:)`` for each text in turn would return, including the
    ///   existing ID for a text already stored, or repeated earlier in `texts`.
    ///
    /// Not atomic: if a save throws, texts before it may already be saved.
    @discardableResult
    public func save(
        contentsOf texts: some Sequence<String>,
        metadata: [String: String] = [:]
    ) async throws -> [UInt64] {
        try await save(contentsOf: texts.map { (text: $0, metadata: metadata) })
    }

    /// Persist many texts, each with its own metadata, embedding and writing them
    /// in batches.
    ///
    /// - Returns: One frame ID per document, in input order: what calling
    ///   ``save(_:metadata:)`` for each document in turn would return, including the
    ///   existing ID for a document already stored, or repeated earlier in `documents`.
    ///
    /// Not atomic: if a save throws, documents before it may already be saved.
    @discardableResult
    public func save(
        contentsOf documents: some Sequence<(text: String, metadata: [String: String])>
    ) async throws -> [UInt64] {
        try await orchestrator.remember(batch: Array(documents))
    }

    /// Import many documents, each with its own metadata, as one atomic write: the fast way
    /// to load a large corpus.
    ///
    /// Saves what ``save(contentsOf:)`` would: the same frames, chunks, vectors and text
    /// index entries, so searches return the same results. Instead of writing through the
    /// write-ahead log and committing every few thousand documents, it writes each document
    /// straight to the store, embeds in batches of ``Config/ingestBatchSize``, indexes its
    /// text while it writes, and publishes everything in a single commit at the end.
    ///
    /// - Returns: One frame ID per document, in input order: what calling
    ///   ``save(_:metadata:)`` for each document in turn would return, including the
    ///   existing ID for a document already stored, or repeated earlier in `documents`.
    ///
    /// Atomic: nothing of the import is visible to searches or durable until it returns. If
    /// it throws, or the process stops before it returns, the store holds exactly what it held
    /// before the call, and the space the import wrote is reused by later writes.
    ///
    /// It first commits pending saves, as ``flush()`` would. While it runs, other saves,
    /// deletes and flushes on this store wait and then run after it. Searches see the store as
    /// it was before the import. Text and hybrid searches wait from the end of its first
    /// batch of 1,024 documents until the commit, while its text is indexed.
    ///
    /// Memory: until the commit, it holds every new frame's record (with its text and
    /// metadata) and every vector, about `4 × dimensions` bytes per searchable frame. For
    /// 100,000 MS MARCO passages with 384-dimension vectors the benchmark process peaked at
    /// 1.4 GB, its own copy of the dataset included. Split a corpus too large for that into
    /// several calls; each one is atomic on its own. A call whose frames cannot fit one
    /// commit's TOC or text index throws `capacityExceeded` at the first batch that does not
    /// fit, before the commit.
    @discardableResult
    public func importDocuments(
        _ documents: some Sequence<(text: String, metadata: [String: String])>
    ) async throws -> [UInt64] {
        try await orchestrator.importDocuments(Array(documents))
    }

    /// Persist multiple texts in one call, in order.
    ///
    /// Not atomic: each text is saved separately. If one save throws, the texts
    /// before it stay saved.
    public func save<each S: StringProtocol>(_ texts: repeat each S) async throws {
        repeat _ = try await orchestrator.remember(String(each texts))
    }

    /// Search memory and return ranked context.
    public func search(_ query: String, options: SearchOptions = .default) async throws -> Results {
        let frameFilter = FrameFilter(includeSurrogates: options.includeSurrogates)
        let mappedTimeRange = options.timeRange.map { SearchTimeRange(after: $0.afterMs, before: $0.beforeMs) }
        let tokenRange = SearchOptions.maxContextTokensRange
        let maxContextTokens = options.maxContextTokens.map {
            min(max($0, tokenRange.lowerBound), tokenRange.upperBound)
        }
        let execution = try await orchestrator.recallExecution(
            query: query,
            mode: options.modeRequest,
            frameFilter: frameFilter,
            timeRange: mappedTimeRange,
            topK: options.topK,
            maxContextTokens: maxContextTokens,
            inferTimeRange: options.inferTimeRange
        )
        return execution.context
    }

    /// Search with inline option customization.
    public func search(_ query: String, configure: (inout SearchOptions) -> Void) async throws -> Results {
        var options = SearchOptions.default
        configure(&options)
        return try await search(query, options: options)
    }

    /// Search with an optional strategy and reranker.
    ///
    /// `strategy` is required at the call site (pass `nil` to skip) so this overload
    /// does not collide with ``search(_:options:)``.
    public func search(
        _ query: String,
        strategy: (any SearchStrategy)?,
        reranker: (any ResultReranker)? = nil,
        options: SearchOptions = .default
    ) async throws -> Results {
        var resolved = options
        strategy?.configure(&resolved)
        let results = try await search(query, options: resolved)
        guard let reranker else { return results }
        return try await reranker.rerank(query: query, results: results)
    }

    /// Soft-delete a memory frame and remove it from enabled search indexes.
    ///
    /// Deleting a document frame (the ID ``save(_:metadata:)`` returns) also
    /// deletes the chunk frames a long text was split into, and frames derived
    /// from those chunks. This holds even when the document was already deleted.
    ///
    /// Used by forget tooling and callers that need to retract a specific frame ID
    /// returned from ``search(_:options:)``.
    public func delete(frameID: UInt64) async throws {
        try await orchestrator.delete(frameId: frameID)
    }

    /// Deletes several frames (and their chunk frames) in one commit. An
    /// unknown ID throws before anything is deleted.
    package func delete(frameIDs: [UInt64]) async throws {
        try await orchestrator.delete(frameIds: frameIDs)
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Embed live searchable frames that have no vectors, using the attached provider.
    ///
    /// Idempotent: frames that already have pending or committed vectors are skipped.
    /// Throws ``WaxError/missingEmbedder`` when no provider is attached — never invents vectors.
    /// Call ``flush()`` afterward to commit the new vectors.
    @discardableResult
    public func backfillUnembedded() async throws -> UInt64 {
        try await orchestrator.backfillUnembedded()
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
        /// Live searchable frames that currently have no pending or committed vector.
        /// `0` when vector coverage cannot be read; ``embeddingStatus`` is then
        /// `.degraded` with a "vector coverage unknown" reason.
        public var framesWithoutVectors: UInt64
        /// 1 when this open dropped a torn tail of uncommitted writes left by a crash, otherwise 0.
        /// Committed data is never dropped.
        public var walReplayTruncationCount: UInt64

        public init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            vectorSearchEnabled: Bool,
            queryEmbedderConfigured: Bool,
            queryEmbeddingCircuitOpen: Bool,
            embedderIdentity: EmbeddingIdentity?,
            embeddingStatus: EmbeddingStatus = .disabled,
            framesWithoutVectors: UInt64 = 0,
            walReplayTruncationCount: UInt64 = 0
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.vectorSearchEnabled = vectorSearchEnabled
            self.queryEmbedderConfigured = queryEmbedderConfigured
            self.queryEmbeddingCircuitOpen = queryEmbeddingCircuitOpen
            self.embedderIdentity = embedderIdentity
            self.embeddingStatus = embeddingStatus
            self.framesWithoutVectors = framesWithoutVectors
            self.walReplayTruncationCount = walReplayTruncationCount
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
            queryEmbedderConfigured: runtime.embeddingStatus.isQueryEmbedderConfigured,
            queryEmbeddingCircuitOpen: runtime.queryEmbeddingCircuitOpen,
            embedderIdentity: runtime.embeddingStatus.identity,
            embeddingStatus: runtime.embeddingStatus,
            framesWithoutVectors: runtime.framesWithoutVectors,
            walReplayTruncationCount: runtime.wal.replayTruncationCount
        )
    }

    package func setSearchSnapshotHoldForTesting(_ duration: Duration?) async {
        await orchestrator.setSearchSnapshotHoldForTesting(duration)
    }

    /// The built-in `.automatic` chose for this store, or `nil` for other embedding sources.
    package var automaticProviderForTesting: BuiltInEmbeddingProvider? {
        orchestrator.automaticProvider
    }

    private static func openRequest(for config: Config) -> EmbeddingOpenRequest {
        guard config.enableVectorSearch else { return .disabled }
        switch config.embedding {
        case .automatic:
            return .automatic(.e5, .default)
        case .builtIn(let provider, let options):
            return .builtIn(provider, options)
        case .custom(let provider):
            return .custom(provider)
        }
    }

    private static func makeOrchestratorConfig(_ config: Config, reranking: RerankStage?) -> OrchestratorConfig {
        var resolved = OrchestratorConfig.default
        resolved.enableTextSearch = config.enableTextSearch
        resolved.enableVectorSearch = config.enableVectorSearch
        resolved.enableStructuredMemory = config.enableStructuredMemory
        resolved.enableAccessStatsScoring = config.enableAccessStatsScoring
        resolved.enableAsyncEnrichment = config.enableAsyncEnrichment
        resolved.ingestConcurrency = config.ingestConcurrency
        resolved.ingestBatchSize = config.ingestBatchSize
        resolved.requireOnDeviceProviders = config.requireOnDeviceProviders
        resolved.catchUpTextIndexOnOpen = true
        resolved.reranking = reranking
        return resolved
    }
}

public protocol SearchStrategy: Sendable {
    func configure(_ options: inout Memory.SearchOptions)
}

public protocol ResultReranker: Sendable {
    func rerank(query: String, results: Memory.Results) async throws -> Memory.Results
}
