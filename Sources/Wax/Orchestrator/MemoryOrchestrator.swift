import Foundation
import WaxCore
import WaxVectorSearch

/// High-level orchestrator for text memory RAG, managing ingest, recall, and lifecycle on a Wax store.
package actor MemoryOrchestrator {
    package struct RememberResult: Sendable, Equatable {
        package var frameId: UInt64
        package var framesAdded: UInt64
        package var deduplicated: Bool
        package var searchable: Bool

        package init(
            frameId: UInt64,
            framesAdded: UInt64,
            deduplicated: Bool,
            searchable: Bool
        ) {
            self.frameId = frameId
            self.framesAdded = framesAdded
            self.deduplicated = deduplicated
            self.searchable = searchable
        }
    }

    /// Policy controlling when to compute query embeddings for vector search.
    private enum QueryEmbeddingPolicy: Sendable, Equatable {
        case never
        case ifAvailable
        case always
    }

    /// Provider plus refined batch/query existentials, probed once at attach.
    private struct AttachedEmbedder: Sendable {
        let provider: any EmbeddingProvider
        let batch: (any BatchEmbeddingProvider)?
        let queryAware: (any QueryAwareEmbeddingProvider)?

        init(provider: any EmbeddingProvider) {
            self.provider = provider
            self.batch = provider as? BatchEmbeddingProvider
            self.queryAware = provider as? QueryAwareEmbeddingProvider
        }
    }

    /// Total lifecycle of the embedding provider. Replaces the former
    /// `(embedder?, embeddingStatus, text-only-write flag)` triple so illegal
    /// combinations are unrepresentable.
    private enum EmbedderLifecycle: Sendable {
        case disabled
        /// Provider still compiling. `wroteTextOnly` records that saves persisted
        /// without vectors while waiting, forcing the first attach to report degraded.
        case loading(wroteTextOnly: Bool)
        case ready(
            attached: AttachedEmbedder,
            degradedReason: String?
        )
        case unavailable(reason: String)
    }

    /// Stable search hit DTO for MCP and other raw-search callers.
    package struct MemorySearchHit: Sendable, Equatable {
        package var frameId: UInt64
        package var score: Float
        package var previewText: String?
        package var sources: [SearchResponse.Source]
        package var metadata: [String: String]
        package var explanations: [String]

        package init(
            frameId: UInt64,
            score: Float,
            previewText: String?,
            sources: [SearchResponse.Source],
            metadata: [String: String] = [:],
            explanations: [String] = []
        ) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
            self.metadata = metadata
            self.explanations = explanations
        }
    }

    package struct SearchExecution: Sendable, Equatable {
        package var hits: [MemorySearchHit]
        package var requestedMode: SearchMode
        package var effectiveMode: SearchMode
        package var queryEmbeddingState: RAGContext.QueryEmbeddingState

        package init(
            hits: [MemorySearchHit],
            requestedMode: SearchMode,
            effectiveMode: SearchMode,
            queryEmbeddingState: RAGContext.QueryEmbeddingState
        ) {
            self.hits = hits
            self.requestedMode = requestedMode
            self.effectiveMode = effectiveMode
            self.queryEmbeddingState = queryEmbeddingState
        }
    }

    package struct RecallExecution: Sendable, Equatable {
        package var context: RAGContext
        package var requestedMode: SearchMode
        package var effectiveMode: SearchMode
        package var queryEmbeddingState: RAGContext.QueryEmbeddingState

        package init(
            context: RAGContext,
            requestedMode: SearchMode,
            effectiveMode: SearchMode,
            queryEmbeddingState: RAGContext.QueryEmbeddingState
        ) {
            self.context = context
            self.requestedMode = requestedMode
            self.effectiveMode = effectiveMode
            self.queryEmbeddingState = queryEmbeddingState
        }
    }

    /// Runtime stats DTO exposed to external callers.
    package struct RuntimeStats: Sendable, Equatable {
        package var frameCount: UInt64
        package var pendingFrames: UInt64
        package var generation: UInt64
        package var wal: WaxWALStats
        package var storeURL: URL
        package var vectorSearchEnabled: Bool
        package var queryEmbedderConfigured: Bool
        package var queryEmbedderReady: Bool
        package var queryEmbeddingCircuitOpen: Bool
        package var structuredMemoryEnabled: Bool
        package var accessStatsScoringEnabled: Bool
        package var embedderIdentity: EmbeddingIdentity?
        package var embeddingStatus: EmbeddingStatus
        package var framesWithoutVectors: UInt64

        package init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            generation: UInt64,
            wal: WaxWALStats,
            storeURL: URL,
            vectorSearchEnabled: Bool,
            queryEmbedderConfigured: Bool,
            queryEmbedderReady: Bool,
            queryEmbeddingCircuitOpen: Bool,
            structuredMemoryEnabled: Bool,
            accessStatsScoringEnabled: Bool,
            embedderIdentity: EmbeddingIdentity?,
            embeddingStatus: EmbeddingStatus = .disabled,
            framesWithoutVectors: UInt64 = 0
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.generation = generation
            self.wal = wal
            self.storeURL = storeURL
            self.vectorSearchEnabled = vectorSearchEnabled
            self.queryEmbedderConfigured = queryEmbedderConfigured
            self.queryEmbedderReady = queryEmbedderReady
            self.queryEmbeddingCircuitOpen = queryEmbeddingCircuitOpen
            self.structuredMemoryEnabled = structuredMemoryEnabled
            self.accessStatsScoringEnabled = accessStatsScoringEnabled
            self.embedderIdentity = embedderIdentity
            self.embeddingStatus = embeddingStatus
            self.framesWithoutVectors = framesWithoutVectors
        }
    }

    package struct SessionRuntimeStats: Sendable, Equatable {
        package var active: Bool
        package var sessionId: UUID?
        package var sessionFrameCount: Int
        package var sessionTokenEstimate: Int
        package var pendingFramesStoreWide: UInt64
        package var countsIncludePending: Bool

        package init(
            active: Bool,
            sessionId: UUID?,
            sessionFrameCount: Int,
            sessionTokenEstimate: Int,
            pendingFramesStoreWide: UInt64,
            countsIncludePending: Bool
        ) {
            self.active = active
            self.sessionId = sessionId
            self.sessionFrameCount = sessionFrameCount
            self.sessionTokenEstimate = sessionTokenEstimate
            self.pendingFramesStoreWide = pendingFramesStoreWide
            self.countsIncludePending = countsIncludePending
        }
    }

    package struct HandoffRecord: Sendable, Equatable {
        package var frameId: UInt64
        package var timestampMs: Int64
        package var content: String
        package var project: String?
        package var pendingTasks: [String]

        package init(frameId: UInt64, timestampMs: Int64, content: String, project: String?, pendingTasks: [String]) {
            self.frameId = frameId
            self.timestampMs = timestampMs
            self.content = content
            self.project = project
            self.pendingTasks = pendingTasks
        }
    }

    private struct SessionRuntimeStatsCacheEntry: Sendable, Equatable {
        var generation: UInt64
        var frameIds: [UInt64]
        var tokenEstimate: Int
    }

    private static let accessStatsFrameKind = "wax.internal.access_stats"
    private static let accessStatsLabel = "wax.internal"
    private static let accessStatsMarkerKey = "wax.internal.kind"
    private static let accessStatsMarkerValue = "access_stats"
    private static let contentHashMetadataKey = "wax.content.hash"

    let wax: Wax
    let config: OrchestratorConfig
    private let ragBuilder: FastRAGContextBuilder
    private let handoffWriteMutex = AsyncMutex()
    private let flushMutex = AsyncMutex()

    let session: WaxSession
    private var embedderLifecycle: EmbedderLifecycle
    private var embeddingCache: EmbeddingMemoizer?
    private var isClosed = false
    private var readinessFollowTask: Task<Void, Never>?
    package var searchSnapshotHoldForTesting: Duration? = nil

    package func setSearchSnapshotHoldForTesting(_ duration: Duration?) {
        searchSnapshotHoldForTesting = duration
    }
    package var accessStatsPersistenceHoldForTesting: Duration? = nil

    package func setAccessStatsPersistenceHoldForTesting(_ duration: Duration?) {
        accessStatsPersistenceHoldForTesting = duration
    }
    private let enrichmentPipeline: EnrichmentPipeline?
    private let accessStatsManager = AccessStatsManager()
    private var accessStatsFrameId: UInt64?
    private var hasEnsuredMemoryBinding = false
    /// Injectable wall-clock source (ms since epoch). Defaults to real time at this
    /// shell boundary so recall decisions remain pure functions of `(store, query, nowMs)`.
    private let nowProvider: @Sendable () -> Int64
    private var queryEmbeddingCircuitOpenedAtMs: Int64?

    /// Externally visible status, derived from ``embedderLifecycle`` so wire
    /// values stay identical to the pre-lifecycle behavior.
    private var embeddingStatus: EmbeddingStatus {
        switch embedderLifecycle {
        case .disabled:
            .disabled
        case .loading:
            .loading
        case .ready(let attached, let degradedReason):
            if let degradedReason {
                .degraded(attached.provider.identity, reason: degradedReason)
            } else {
                .active(attached.provider.identity)
            }
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }

    /// Atomic snapshot of the ready provider and its attach-time refined existentials,
    /// so a concurrent attach cannot pair one generation's provider with another's.
    private var readyEmbedderSnapshot: AttachedEmbedder? {
        if case .ready(let attached, _) = embedderLifecycle {
            return attached
        }
        return nil
    }

    /// Stays open for `config.queryEmbeddingCircuitCooldown` after a query-embedding
    /// timeout, then allows one half-open probe; probe success closes the circuit,
    /// another timeout re-opens it for a fresh cooldown window.
    private var queryEmbeddingCircuitOpen: Bool {
        guard let openedAtMs = queryEmbeddingCircuitOpenedAtMs else { return false }
        return max(0, nowProvider() - openedAtMs) < Self.circuitCooldownMs(config.queryEmbeddingCircuitCooldown)
    }

    /// Circuit uses wall-clock epoch ms with the same open/half-open thresholds;
    /// sub-ms `Duration` components truncate. A backward system-clock step can
    /// extend an open window until wall time catches up (self-heals on next probe).
    private static func circuitCooldownMs(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private var requiresEmbedderForSave: Bool {
        switch embeddingStatus {
        case .active, .degraded, .unavailable:
            true
        case .disabled, .loading:
            false
        }
    }
    private var sessionRuntimeStatsCache: [UUID: SessionRuntimeStatsCacheEntry] = [:]
    private var lastStructuredSystemMs: Int64?

    private var currentSessionId: UUID?
    var flushCount: UInt64 = 0
    var lastWriteActivityAt: ContinuousClock.Instant = .now
    var lastScheduledLiveSetMaintenanceReport: ScheduledLiveSetMaintenanceReport?
    var scheduledLiveSetMaintenanceTask: Task<Void, Never>?
    var scheduledLiveSetMaintenanceQueued = false
    var scheduledLiveSetMaintenanceLastCompletedAt: ContinuousClock.Instant?

    package init(
        at url: URL,
        config: OrchestratorConfig = .default,
        waxOptions: WaxOptions = .init()
    ) async throws {
        try await self.init(
            at: url,
            config: config,
            embedder: nil,
            waxOptions: waxOptions
        )
    }

    package init(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        waxOptions: WaxOptions = .init(),
        initialEmbeddingStatus: EmbeddingStatus? = nil,
        nowMsProvider: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) async throws {
        // Prewarm tokenizer in parallel with Wax file operations
        // This overlaps BPE loading (~9-13ms) with I/O-bound file operations
        async let tokenizerPrewarm: Bool = { 
            do {
                _ = try await TokenCounter.preload()
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "tokenizer prewarm",
                    fallback: "cold start on first use"
                )
            }
            return true
        }()

        if config.requireOnDeviceProviders, let localEmbedder = embedder {
            try ProviderValidation.validateOnDevice(
                [.init(name: "embedding provider", executionMode: localEmbedder.executionMode)],
                orchestratorName: "MemoryOrchestrator"
            )
        }
        
        if FileManager.default.fileExists(atPath: url.path) {
            self.wax = try await Wax.open(at: url, options: waxOptions)
        } else {
            self.wax = try await Wax.create(
                at: url,
                walSize: Constants.defaultWalSize,
                options: waxOptions
            )
        }

        // Auto-disable vector search when no embedder is provided and no pre-existing
        // vector index exists. This lets the simple `MemoryOrchestrator(at:)` initializer
        // work out-of-the-box with text-only search instead of throwing an error.
        // Callers that pass `initialEmbeddingStatus` own the missing-provider rule
        // (index remains + unavailable / loading + live attach).
        var resolvedConfig = config
        let existingMemoryBinding = await wax.memoryBinding()
        var lifecycle: EmbedderLifecycle
        if let initialEmbeddingStatus {
            lifecycle = Self.lifecycle(from: initialEmbeddingStatus, provider: embedder)
            if case .disabled = initialEmbeddingStatus {
                resolvedConfig.enableVectorSearch = false
            }
        } else if resolvedConfig.enableVectorSearch, embedder == nil, await wax.committedVecIndexManifest() == nil {
            resolvedConfig.enableVectorSearch = false
            lifecycle = .disabled
            WaxDiagnostics.logSwallowed(
                WaxError.io("vector search requested but no EmbeddingProvider configured"),
                context: "MemoryOrchestrator init",
                fallback: "text-only search; Memory(at:) auto-wires the built-in MiniLM embedder on iOS 18/macOS 15+"
            )
        } else if let embedder {
            lifecycle = .ready(
                attached: AttachedEmbedder(provider: embedder),
                degradedReason: nil
            )
        } else if resolvedConfig.enableVectorSearch {
            lifecycle = .unavailable(reason: "no embedding provider")
        } else {
            lifecycle = .disabled
        }
        if embedder != nil, await Self.storeHasUnembeddedChunks(wax) {
            switch lifecycle {
            case .ready(let attached, _):
                lifecycle = .ready(
                    attached: attached,
                    degradedReason: "some saved frames have no vectors"
                )
            case .disabled, .loading, .unavailable:
                break
            }
        }
        if let binding = existingMemoryBinding, !binding.isEmpty, let embedder {
            guard let identity = embedder.identity else {
                try? await wax.close()
                throw WaxError.io(
                    "memory binding requires an identifiable embedder provider"
                )
            }
            guard MemoryBindingCompatibility.isCompatible(binding, with: identity) else {
                let mismatch = MemoryBindingCompatibility.mismatchReason(binding, with: identity) ?? "unknown mismatch"
                try? await wax.close()
                throw WaxError.io("memory binding mismatch with embedder identity (\(mismatch))")
            }
        }

        self.config = resolvedConfig
        self.ragBuilder = FastRAGContextBuilder()
        self.embedderLifecycle = lifecycle
        self.nowProvider = nowMsProvider
        self.embeddingCache = EmbeddingMemoizer.fromConfig(
            capacity: resolvedConfig.embeddingCacheCapacity,
            enabled: embedder != nil
        )
        self.enrichmentPipeline = resolvedConfig.enableAsyncEnrichment ? EnrichmentPipeline() : nil
        self.hasEnsuredMemoryBinding = existingMemoryBinding != nil

        let preference = resolvedConfig.vectorEnginePreference
        let sessionConfig = WaxSession.Config(
            enableTextSearch: resolvedConfig.enableTextSearch,
            enableVectorSearch: resolvedConfig.enableVectorSearch,
            enableStructuredMemory: resolvedConfig.enableStructuredMemory,
            vectorEnginePreference: preference,
            vectorMetric: .cosine,
            vectorDimensions: embedder?.dimensions
        )
        self.session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        // Wait for tokenizer prewarm to complete (should already be done by now)
        _ = await tokenizerPrewarm
        if let enrichmentPipeline {
            let session = self.session
            await enrichmentPipeline.start { task in
                EnrichmentResult(
                    frameId: task.frameId,
                    keywords: KeywordExtractor.extract(from: task.text),
                    entities: EntityExtractor.extract(from: task.text)
                )
            } resultHandler: { result in
                try await Self.persistEnrichmentResult(result, in: session)
            }
        }
        if resolvedConfig.enableAccessStatsScoring {
            try await loadPersistedAccessStatsIfNeeded()
        }
    }

    /// Maps a caller-declared status onto the lifecycle. Readiness producers always
    /// pair `active`/`degraded` with a provider; if one ever arrives without, the
    /// store falls back to the unavailable state used for vector-enabled stores
    /// that have no provider.
    private static func lifecycle(
        from status: EmbeddingStatus,
        provider: (any EmbeddingProvider)?
    ) -> EmbedderLifecycle {
        switch status {
        case .disabled:
            .disabled
        case .loading:
            .loading(wroteTextOnly: false)
        case .active:
            readyLifecycle(provider: provider, degradedReason: nil)
        case .degraded(_, let reason):
            readyLifecycle(provider: provider, degradedReason: reason)
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }

    private static func readyLifecycle(
        provider: (any EmbeddingProvider)?,
        degradedReason: String?
    ) -> EmbedderLifecycle {
        guard let provider else { return .unavailable(reason: "no embedding provider") }
        return .ready(attached: AttachedEmbedder(provider: provider), degradedReason: degradedReason)
    }


    // MARK: - Session tagging (v1)

    package func startSession() -> UUID {
        let id = UUID()
        currentSessionId = id
        return id
    }

    package func endSession() {
        currentSessionId = nil
    }

    package func activeSessionId() -> UUID? {
        currentSessionId
    }

    // MARK: - Ingestion

    /// Ingest text content into the memory store, chunking and embedding as configured.
    ///
    /// Content is split into chunks and written in batches. Each batch is committed
    /// independently to the underlying store.
    ///
    /// - Important: Batch writes are **not atomic**. If a failure occurs mid-ingest
    ///   (e.g., embedding provider error, I/O failure), earlier batches may already be
    ///   committed while later batches are lost. The committed state remains consistent
    ///   (WAL guarantees crash safety), but the ingested content may be incomplete.
    ///   Callers requiring all-or-nothing semantics should validate post-ingest or
    ///   implement their own rollback by superseding the document frame on failure.
    @discardableResult
    package func remember(_ content: String, metadata: [String: String] = [:]) async throws -> RememberResult {
        lastWriteActivityAt = .now
        let contentData = Data(content.utf8)
        let contentHash = ContentHasher.hash(contentData).hexString
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        let attached = readyEmbedderSnapshot
        let localEmbedder = attached?.provider

        var docMeta = Metadata(metadata)
        docMeta.entries[Self.contentHashMetadataKey] = contentHash
        if docMeta.entries["session_id"] == nil, let session = currentSessionId {
            docMeta.entries["session_id"] = session.uuidString
        }
        let effectiveSessionId = docMeta.entries["session_id"]
        if let existingProbe = await wax.rememberDedupProbe(
            contentHash: contentHash,
            metadata: docMeta.entries,
            expectedChunkCount: chunks.count,
            embeddingIdentity: Self.rememberDedupEmbeddingIdentity(from: localEmbedder?.identity)
        ) {
            if existingProbe.isComplete {
                return RememberResult(
                    frameId: existingProbe.documentId,
                    framesAdded: 0,
                    deduplicated: true,
                    searchable: !chunks.isEmpty && (
                        config.enableTextSearch || (config.enableVectorSearch && localEmbedder != nil)
                    )
                )
            }
            // Single-chunk remember writes only the document. A matching
            // document is not complete unless it is actually searchable.
            if chunks.count == 1 {
                try await ensureSingleChunkDocumentSearchable(
                    documentId: existingProbe.documentId,
                    text: chunks[0]
                )
                return RememberResult(
                    frameId: existingProbe.documentId,
                    framesAdded: 0,
                    deduplicated: true,
                    searchable: true
                )
            }
        }

        let chunkCount = chunks.count
        let localSession = session
        let cache = embeddingCache
        let batchSize = max(1, config.ingestBatchSize)
        let useVectorSearch = config.enableVectorSearch
        let bindingForEmbedderIdentity: MemoryBinding?
        if let identity = localEmbedder?.identity {
            bindingForEmbedderIdentity = MemoryBindingCompatibility.binding(from: identity)
        } else {
            bindingForEmbedderIdentity = nil
        }

        guard !chunks.isEmpty else {
            let frameId = try await localSession.put(
                contentData,
                options: FrameMetaSubset(
                    role: .document,
                    metadata: docMeta
                )
            )
            return RememberResult(
                frameId: frameId,
                framesAdded: 1,
                deduplicated: false,
                searchable: false
            )
        }

        if useVectorSearch, localEmbedder == nil {
            if requiresEmbedderForSave {
                throw WaxError.missingEmbedder
            }
            // Text-only save while waiting for the provider; the eventual attach
            // must report degraded instead of active.
            if case .loading = embedderLifecycle {
                embedderLifecycle = .loading(wroteTextOnly: true)
            }
        }

        if chunkCount == 1 {
            let chunk = chunks[0]
            var docOptions = FrameMetaSubset(
                role: .document,
                metadata: docMeta
            )
            docOptions.searchText = chunk

            let chunkEmbedding: [Float]?
            if useVectorSearch, let attached {
                chunkEmbedding = try await Self.embedOne(
                    chunk,
                    attached: attached,
                    cache: cache,
                    timeout: config.ingestEmbeddingTimeout
                )
            } else {
                chunkEmbedding = nil
            }

            // Put without identity so doc metadata stays user keys + hash.
            // `put(..., identity:)` stamps wax.embedding.* and the rematch
            // probe uses exact metadata equality without those keys.
            let frameId = try await localSession.put(contentData, options: docOptions)
            if let chunkEmbedding {
                try await wax.putEmbedding(frameId: frameId, vector: chunkEmbedding)
                try await ensureMemoryBindingIfNeeded(bindingForEmbedderIdentity)
            }

            if config.enableTextSearch {
                try await localSession.indexText(frameId: frameId, text: chunk)
            }
            if let enrichmentPipeline {
                try await enrichmentPipeline.enqueue(
                    EnrichmentTask(frameId: frameId, text: chunk)
                )
            }
            return RememberResult(
                frameId: frameId,
                framesAdded: 1,
                deduplicated: false,
                searchable: config.enableTextSearch || chunkEmbedding != nil
            )
        }

        struct IngestBatchResult {
            let index: Int
            let embeddings: [[Float]]?
        }

        let batchRanges: [(index: Int, range: Range<Int>)] = stride(from: 0, to: chunkCount, by: batchSize)
            .enumerated()
            .map { idx, start in
                let end = min(start + batchSize, chunkCount)
                return (idx, start..<end)
            }

        let parallelism = max(1, config.ingestConcurrency)
        let ingestTimeout = config.ingestEmbeddingTimeout

        var preparedEmbeddingsByBatch: [Int: [[Float]]] = [:]
        preparedEmbeddingsByBatch.reserveCapacity(batchRanges.count)
        var preparedBatchCount = 0

        try await withThrowingTaskGroup(of: IngestBatchResult.self) { group in
            func enqueue(_ entry: (index: Int, range: Range<Int>)) {
                group.addTask {
                    let batchChunks = Array(chunks[entry.range])

                    if let attached, useVectorSearch {
                        let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
                            chunks: batchChunks,
                            attached: attached,
                            cache: cache,
                            timeout: ingestTimeout
                        )
                        return IngestBatchResult(
                            index: entry.index,
                            embeddings: embeddings
                        )
                    }

                    return IngestBatchResult(
                        index: entry.index,
                        embeddings: nil
                    )
                }
            }

            var iterator = batchRanges.makeIterator()
            let initial = min(parallelism, batchRanges.count)
            var inFlight = 0
            for _ in 0..<initial {
                if let next = iterator.next() {
                    enqueue(next)
                    inFlight += 1
                }
            }

            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1

                if let embeddings = result.embeddings {
                    preparedEmbeddingsByBatch[result.index] = embeddings
                }
                preparedBatchCount += 1

                if let next = iterator.next() {
                    enqueue(next)
                    inFlight += 1
                }
            }
        }

        guard preparedBatchCount == batchRanges.count else {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) prepared batches, got \(preparedBatchCount)"
            )
        }
        let writeVectors = useVectorSearch && localEmbedder != nil
        if writeVectors, preparedEmbeddingsByBatch.count != batchRanges.count {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) prepared embedding batches, got \(preparedEmbeddingsByBatch.count)"
            )
        }
        let docId = try await localSession.put(
            contentData,
            options: FrameMetaSubset(
                role: .document,
                metadata: docMeta
            )
        )

        for entry in batchRanges {
            let batchChunks = Array(chunks[entry.range])
            let batchContents = batchChunks.map { Data($0.utf8) }
            var options: [FrameMetaSubset] = []
            options.reserveCapacity(batchChunks.count)
            for (localIdx, globalIdx) in entry.range.enumerated() {
                var option = FrameMetaSubset()
                option.role = .chunk
                option.parentId = docId
                option.chunkIndex = UInt32(globalIdx)
                option.chunkCount = UInt32(chunkCount)
                option.searchText = batchChunks[localIdx]

                var chunkMeta = Metadata(metadata)
                if let effectiveSessionId {
                    chunkMeta.entries["session_id"] = effectiveSessionId
                }
                option.metadata = chunkMeta
                options.append(option)
            }

            if writeVectors {
                guard let embeddings = preparedEmbeddingsByBatch[entry.index] else {
                    throw WaxError.io("missing prepared embeddings for batch \(entry.index)")
                }
                let frameIds = try await localSession.putBatch(
                    contents: batchContents,
                    embeddings: embeddings,
                    identity: localEmbedder?.identity,
                    options: options
                )
                try await ensureMemoryBindingIfNeeded(bindingForEmbedderIdentity)

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
                if let enrichmentPipeline {
                    for (offset, frameId) in frameIds.enumerated() {
                        try await enrichmentPipeline.enqueue(
                            EnrichmentTask(frameId: frameId, text: batchChunks[offset])
                        )
                    }
                }
            } else {
                let frameIds = try await localSession.putBatch(contents: batchContents, options: options)

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
                if let enrichmentPipeline {
                    for (offset, frameId) in frameIds.enumerated() {
                        try await enrichmentPipeline.enqueue(
                            EnrichmentTask(frameId: frameId, text: batchChunks[offset])
                        )
                    }
                }
            }
        }
        return RememberResult(
            frameId: docId,
            framesAdded: UInt64(chunkCount + 1),
            deduplicated: false,
            searchable: config.enableTextSearch || writeVectors
        )
    }

    private static func rememberDedupEmbeddingIdentity(
        from identity: EmbeddingIdentity?
    ) -> RememberDedupEmbeddingIdentity? {
        guard let identity else { return nil }
        return RememberDedupEmbeddingIdentity(
            provider: identity.provider,
            model: identity.model,
            dimensions: identity.dimensions,
            normalized: identity.normalized
        )
    }

    /// Re-index / re-embed an existing single-chunk document in place (0 new frames).
    /// `searchText` cannot be patched on a written frame; FTS and embeddings can.
    private func ensureSingleChunkDocumentSearchable(
        documentId: UInt64,
        text: String
    ) async throws {
        if await isSingleChunkDocumentSearchable(documentId: documentId, expectedText: text) {
            return
        }

        if config.enableTextSearch {
            let alreadyIndexed = await documentIsInTextIndex(documentId: documentId, text: text)
            if !alreadyIndexed {
                try await session.indexText(frameId: documentId, text: text)
            }
        }

        if config.enableVectorSearch {
            let alreadyEmbedded = await documentHasEmbedding(frameId: documentId)
            if !alreadyEmbedded {
                guard let attached = readyEmbedderSnapshot else {
                    throw WaxError.missingEmbedder
                }
                let localEmbedder = attached.provider
                let embedding = try await Self.embedOne(
                    text,
                    attached: attached,
                    cache: embeddingCache,
                    timeout: config.ingestEmbeddingTimeout
                )
                try await wax.putEmbedding(frameId: documentId, vector: embedding)
                if let identity = localEmbedder.identity {
                    try await ensureMemoryBindingIfNeeded(
                        MemoryBindingCompatibility.binding(from: identity)
                    )
                }
            }
        }
    }

    private func isSingleChunkDocumentSearchable(
        documentId: UInt64,
        expectedText: String
    ) async -> Bool {
        let meta: FrameMeta
        do {
            meta = try await wax.frameMetaIncludingPending(frameId: documentId)
        } catch {
            return false
        }
        let searchText = meta.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !searchText.isEmpty else { return false }

        if config.enableTextSearch {
            let indexed = await documentIsInTextIndex(documentId: documentId, text: expectedText)
            guard indexed else { return false }
        }
        if config.enableVectorSearch {
            let embedded = await documentHasEmbedding(frameId: documentId)
            guard embedded else { return false }
        }
        return true
    }

    private func documentIsInTextIndex(documentId: UInt64, text: String) async -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        do {
            let hits = try await session.searchText(query: query, topK: 64)
            return hits.contains { $0.frameId == documentId }
        } catch {
            return false
        }
    }

    private func documentHasEmbedding(frameId: UInt64) async -> Bool {
        let pending = await wax.pendingEmbeddingMutations()
        if pending.contains(where: { $0.frameId == frameId }) {
            return true
        }
        if let staged = await wax.readStagedVecIndexBytes(),
           Self.vecSegmentContains(frameId: frameId, bytes: staged.bytes) {
            return true
        }
        if let bytes = try? await wax.readCommittedVecIndexBytes(),
           Self.vecSegmentContains(frameId: frameId, bytes: bytes) {
            return true
        }
        return false
    }

    private static func vecSegmentContains(frameId: UInt64, bytes: Data) -> Bool {
        vecSegmentFrameIds(bytes: bytes).contains(frameId)
    }

    private static func vecSegmentFrameIds(bytes: Data) -> Set<UInt64> {
        guard let payload = try? VectorSerializer.decodeVecSegment(from: bytes) else {
            return []
        }
        switch payload {
        case .metal(_, _, let frameIds):
            return Set(frameIds)
        }
    }

    private static func persistEnrichmentResult(
        _ result: EnrichmentResult,
        in session: WaxSession
    ) async throws {
        guard !result.keywords.isEmpty || !result.entities.isEmpty else {
            return
        }

        var metadata = Metadata()
        metadata.entries["wax.enrichment.source_frame_id"] = String(result.frameId)
        if !result.keywords.isEmpty {
            metadata.entries["wax.enrichment.keywords"] = result.keywords.joined(separator: ",")
        }
        if !result.entities.isEmpty {
            metadata.entries["wax.enrichment.entities"] = result.entities
                .map { "\($0.subject)|\($0.predicate)|\($0.object)" }
                .joined(separator: "\n")
        }

        _ = try await session.put(
            Data(renderEnrichmentResult(result).utf8),
            options: FrameMetaSubset(
                kind: FrameKind.other("enrichment").storageValue,
                role: .system,
                parentId: result.frameId,
                searchText: result.keywords.joined(separator: " "),
                metadata: metadata
            )
        )
    }

    private static func renderEnrichmentResult(_ result: EnrichmentResult) -> String {
        var lines: [String] = []
        if !result.keywords.isEmpty {
            lines.append("keywords: \(result.keywords.joined(separator: ", "))")
        }
        if !result.entities.isEmpty {
            lines.append("entities:")
            lines.append(contentsOf: result.entities.map { "- \($0.subject) \($0.predicate) \($0.object)" })
        }
        return lines.joined(separator: "\n")
    }

    private func ensureMemoryBindingIfNeeded(_ binding: MemoryBinding?) async throws {
        guard let binding, !binding.isEmpty, !hasEnsuredMemoryBinding else { return }
        hasEnsuredMemoryBinding = true
#if DEBUG
        Self._recordMemoryBindingEnsureCallForTests()
#endif
        do {
            try await wax.setMemoryBindingIfMissing(binding)
        } catch {
            hasEnsuredMemoryBinding = false
            throw error
        }
    }

    /// Optimized batch embedding preparation with cache-aware batching.
    /// Minimizes cache lookups and maximizes batch embedding efficiency.
    private static func prepareEmbeddingsBatchOptimized(
        chunks: [String],
        attached: AttachedEmbedder,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [[Float]] {
#if DEBUG
        Self._recordBatchPreparationPathCallForTests()
#endif
        let embedder = attached.provider
        var results: [[Float]] = Array(repeating: [], count: chunks.count)
        let cacheKeys: [UInt64]? = if cache != nil {
            chunks.map {
                EmbeddingKey.make(
                    text: $0,
                    identity: embedder.identity,
                    dimensions: embedder.dimensions,
                    normalized: embedder.normalize
                )
            }
        } else {
            nil
        }
        var missingIndices: [Int] = []
        var missingTexts: [String] = []
        missingIndices.reserveCapacity(chunks.count)
        missingTexts.reserveCapacity(chunks.count)

        if let cache, let cacheKeys {
            let cachedValues = await cache.getBatch(cacheKeys)
            for (index, key) in cacheKeys.enumerated() {
                if let cached = cachedValues[key] {
                    results[index] = cached
                } else {
                    missingIndices.append(index)
                    missingTexts.append(chunks[index])
                }
            }
        } else {
            missingIndices = Array(0..<chunks.count)
            missingTexts = chunks
        }

        // Compute missing embeddings using batch API when available
        if !missingTexts.isEmpty {
            let vectors: [[Float]]
            let textsToEmbed = missingTexts // let-bind for @Sendable capture

            // Prefer batch embedding for significantly better throughput
            if let batchEmbedder = attached.batch {
                if let timeout {
                    vectors = try await AsyncTimeout.run(timeout: timeout, operation: "batch ingest embed") {
                        try await batchEmbedder.embed(batch: textsToEmbed)
                    }
                } else {
                    vectors = try await batchEmbedder.embed(batch: textsToEmbed)
                }
            } else {
                var sequentialVectors: [[Float]] = []
                sequentialVectors.reserveCapacity(textsToEmbed.count)
                for text in textsToEmbed {
                    let vector: [Float]
                    if let timeout {
                        let textCopy = text
                        vector = try await AsyncTimeout.run(timeout: timeout, operation: "ingest embed") {
                            try await embedder.embed(textCopy)
                        }
                    } else {
                        vector = try await embedder.embed(text)
                    }
                    sequentialVectors.append(vector)
                }
                vectors = sequentialVectors
            }

            guard vectors.count == missingIndices.count else {
                throw WaxError.encodingError(
                    reason: "batch embedding returned \(vectors.count) vectors for \(missingIndices.count) inputs"
                )
            }

            // Normalize (if needed) and cache results
            let shouldNormalize = embedder.normalize
            var cacheItems: [(key: UInt64, value: [Float])] = []
            cacheItems.reserveCapacity(missingIndices.count)
            for (localIdx, globalIdx) in missingIndices.enumerated() {
                var vec = vectors[localIdx]
                if shouldNormalize && !vec.isEmpty {
                    vec = normalizedL2(vec)
                }
                results[globalIdx] = vec

                if let cacheKeys {
                    cacheItems.append((key: cacheKeys[globalIdx], value: vec))
                }
            }

            if let cache, !cacheItems.isEmpty {
                await cache.setBatch(cacheItems)
            }
        }

        return results
    }
    
    /// Legacy method for backward compatibility
    private static func prepareEmbeddingsBatch(
        chunks: [String],
        attached: AttachedEmbedder,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [[Float]] {
        try await prepareEmbeddingsBatchOptimized(
            chunks: chunks,
            attached: attached,
            cache: cache,
            timeout: timeout
        )
    }

    // MARK: - Recall (Fast RAG)

    package func recall(query: String) async throws -> RAGContext {
        try await executeRecall(
            query: query,
            frameFilter: nil,
            timeRange: nil,
            topK: nil,
            requestedMode: nil
        ).context
    }

    package func recall(query: String, frameFilter: FrameFilter?) async throws -> RAGContext {
        try await executeRecall(
            query: query,
            frameFilter: frameFilter,
            timeRange: nil,
            topK: nil,
            requestedMode: nil
        ).context
    }

    package func recall(query: String, embedding: [Float]) async throws -> RAGContext {
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    package func recall(
        query: String,
        mode: SearchMode,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        topK: Int? = nil
    ) async throws -> RAGContext {
        try await executeRecall(
            query: query,
            frameFilter: frameFilter,
            timeRange: timeRange,
            topK: topK,
            requestedMode: mode
        ).context
    }

    package func recallExecution(
        query: String,
        mode: SearchMode? = nil,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        topK: Int? = nil
    ) async throws -> RecallExecution {
        try await executeRecall(
            query: query,
            frameFilter: frameFilter,
            timeRange: timeRange,
            topK: topK,
            requestedMode: mode
        )
    }

    /// Shared recall implementation: builds the RAG context from the access-stat
    /// snapshot taken before this call. Recall does not record access, so identical
    /// queries stay byte-identical. Stats accrue from explicit get/promote.
    private func buildRecallContext(
        query: String,
        embedding: [Float]?,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        searchTopK: Int? = nil,
        searchMode: SearchMode? = nil
    ) async throws -> RAGContext {
        let preference = config.vectorEnginePreference
        var recallConfig = ragConfigForRecall()
        if let searchTopK {
            recallConfig.searchTopK = max(1, searchTopK)
        }
        if let searchMode {
            recallConfig.searchMode = searchMode
        }
        let resolvedTimeRange = timeRange ?? extractTemporalTimeRange(from: query, anchorMs: recallConfig.deterministicNowMs)
        // Access reasons are attached once during pack. Do not re-fetch stats
        // or re-append the same strings here.
        return try await ragBuilder.build(
            query: query,
            embedding: embedding,
            vectorEnginePreference: preference,
            wax: wax,
            session: session,
            frameFilter: frameFilter,
            timeRange: resolvedTimeRange,
            scopeContext: config.defaultScopeContext,
            accessStatsManager: config.enableAccessStatsScoring ? accessStatsManager : nil,
            config: recallConfig
        )
    }

    /// Performs direct search without context assembly.
    ///
    /// - Parameters:
    ///   - query: Query text.
    ///   - mode: ``Memory/RetrievalMode`` — text-only, vector-only, or hybrid.
    ///     Hybrid may fall back to text when the vector lane is unavailable.
    ///     `vectorOnly` throws if vector search is disabled or no embedder is configured.
    ///   - topK: Maximum number of hits to return.
    /// - Returns: Ranked raw hits.
    package func search(
        query: String,
        mode: SearchMode = .hybrid(),
        topK: Int = 10,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil
    ) async throws -> [MemorySearchHit] {
        try await searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: frameFilter,
            timeRange: timeRange
        ).hits
    }

    package func searchExecution(
        query: String,
        mode: SearchMode = .hybrid(),
        topK: Int = 10,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil
    ) async throws -> SearchExecution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchExecution(
                hits: [],
                requestedMode: mode,
                effectiveMode: .textOnly,
                queryEmbeddingState: .notRequested
            )
        }
        guard topK > 0 else {
            return SearchExecution(
                hits: [],
                requestedMode: mode,
                effectiveMode: .textOnly,
                queryEmbeddingState: .notRequested
            )
        }

        let preference = config.vectorEnginePreference

        let attached = readyEmbedderSnapshot
        if let hold = searchSnapshotHoldForTesting {
            try await Task.sleep(for: hold)
        }
        let queryEmbedding = try await queryEmbeddingResult(
            for: trimmed,
            policy: Self.queryEmbeddingPolicy(for: mode),
            attached: attached
        )
        let searchMode = try Self.resolveSearchMode(
            requested: mode,
            embeddingAvailable: queryEmbedding.embedding != nil
        )

        // Access-aware ranking needs additional candidates so a stale top hit
        // can be displaced by a close, recently/frequently used result. The
        // candidate window is bounded and applies only when the feature is on.
        let searchTopK: Int
        if !config.enableAccessStatsScoring || topK > 16 {
            searchTopK = topK
        } else {
            searchTopK = topK * 3
        }
        // One ranking-now for this search: UnifiedSearch recency and later
        // access ranking must not tick the wall clock twice.
        let searchNowMs = config.rag.deterministicNowMs ?? nowProvider()
        let request = SearchRequest(
            query: trimmed,
            embedding: queryEmbedding.embedding,
            vectorEnginePreference: preference,
            vectorSearchTimeout: config.vectorSearchTimeout,
            mode: searchMode,
            topK: searchTopK,
            timeRange: timeRange,
            frameFilter: frameFilter,
            nowMs: searchNowMs,
            scopeContext: config.defaultScopeContext,
            previewMaxBytes: config.rag.previewMaxBytes
        )
        let response = try await session.search(request)

        let accessStatsMap: [UInt64: FrameAccessStats] = if config.enableAccessStatsScoring {
            await AccessFrequencyRanker.statsForRanking(
                frameIds: response.results.map(\.frameId),
                manager: accessStatsManager,
                wax: wax
            )
        } else {
            [:]
        }
        let scoredResults = config.enableAccessStatsScoring
            ? AccessFrequencyRanker.rerank(
                results: response.results,
                query: trimmed,
                accessStats: accessStatsMap,
                nowMs: searchNowMs,
                maxWindow: searchTopK
            )
            : response.results
        let hits = scoredResults.prefix(topK).map { result in
            let accessReasons = MemorySemantics.accessReasons(
                stats: accessStatsMap[result.frameId],
                metadata: result.metadata,
                nowMs: searchNowMs
            ).reasons
            return MemorySearchHit(
                frameId: result.frameId,
                score: result.score,
                previewText: result.previewText,
                sources: result.sources,
                metadata: result.metadata,
                explanations: dedupedExplanations(result.explanations + accessReasons)
            )
        }
        return SearchExecution(
            hits: hits,
            requestedMode: mode,
            effectiveMode: searchMode,
            queryEmbeddingState: queryEmbedding.state
        )
    }

    /// Returns lightweight store/runtime stats useful for operators and MCP tools.
    package func runtimeStats() async -> RuntimeStats {
        let stats = await wax.stats()
        let walStats = await wax.walStats()
        let storeURL = await wax.fileURL()

        return RuntimeStats(
            frameCount: stats.frameCount,
            pendingFrames: stats.pendingFrames,
            generation: stats.generation,
            wal: walStats,
            storeURL: storeURL,
            vectorSearchEnabled: config.enableVectorSearch,
            queryEmbedderConfigured: embeddingStatus.isQueryEmbedderConfigured,
            queryEmbedderReady: await isQueryEmbedderReady(),
            queryEmbeddingCircuitOpen: queryEmbeddingCircuitOpen,
            structuredMemoryEnabled: config.enableStructuredMemory,
            accessStatsScoringEnabled: config.enableAccessStatsScoring,
            embedderIdentity: embeddingStatus.identity,
            embeddingStatus: embeddingStatus,
            framesWithoutVectors: await Self.framesWithoutVectorsCount(wax)
        )
    }

    /// Select a real live searchable frame for operator health canaries. The
    /// caller can then constrain the vector query to this ID instead of
    /// validating a synthetic temporary store.
    package func healthCanaryFrame() async -> SurrogateSourceFrame? {
        await wax.activeSurrogateSourceFrames().first
    }

    /// True when query embedding can run now (``.active`` / ``.degraded``).
    package func isQueryEmbedderReady() async -> Bool {
        embeddingStatus.isQueryEmbedderConfigured
    }

    package func shouldDeferRememberUntilEmbedderReady() async -> Bool {
        guard config.enableVectorSearch else { return false }
        if case .loading = embeddingStatus { return true }
        return false
    }

    /// Embed live searchable frames that have no vectors using the attached provider.
    ///
    /// Returns the number of frames newly embedded. Already-vectorized frames are
    /// skipped. Throws ``WaxError/missingEmbedder`` when no provider is attached.
    @discardableResult
    package func backfillUnembedded() async throws -> UInt64 {
        guard config.enableVectorSearch, let attached = readyEmbedderSnapshot else {
            throw WaxError.missingEmbedder
        }
        let embedder = attached.provider

        let missing = await unembeddedLiveSources()
        guard !missing.isEmpty else {
            await refreshEmbeddingCoverage()
            return 0
        }

        try await session.ensureVectorEngine(dimensions: embedder.dimensions)

        let batchSize = max(1, config.ingestBatchSize)
        var embedded: UInt64 = 0
        var index = 0
        while index < missing.count {
            let end = min(index + batchSize, missing.count)
            let batch = Array(missing[index..<end])
            let vectors = try await Self.prepareEmbeddingsBatchOptimized(
                chunks: batch.map(\.searchText),
                attached: attached,
                cache: embeddingCache,
                timeout: config.ingestEmbeddingTimeout
            )
            try await wax.putEmbeddingBatch(
                frameIds: batch.map(\.id),
                vectors: vectors
            )
            if let identity = embedder.identity {
                try await ensureMemoryBindingIfNeeded(
                    MemoryBindingCompatibility.binding(from: identity)
                )
            }
            embedded += UInt64(batch.count)
            index = end
        }

        await refreshEmbeddingCoverage()
        return embedded
    }

    /// Wait until automatic compile has attached, or throw if it failed.
    ///
    /// Do not call ``remember(_:metadata:)`` while the status is ``.loading``
    /// with no provider attached — that path persists text-only and is not backfilled.
    package func waitUntilReadyForRemember() async throws {
        if let readinessFollowTask {
            await readinessFollowTask.value
        }
        switch embeddingStatus {
        case .active, .degraded, .disabled:
            return
        case .loading:
            throw WaxError.io("embedding provider is still loading")
        case .unavailable(let reason):
            throw WaxError.io(reason)
        }
    }

    package func accessStatsSnapshot() async -> [UInt64: FrameAccessStats] {
        await accessStatsManager.snapshot()
    }

    /// Records an explicit use of a frame (get/promote). Search and recall rank
    /// against the stored snapshot but do not mutate engagement.
    package func recordAccess(frameId: UInt64) async {
        let nowMs = config.rag.deterministicNowMs ?? nowProvider()
        await recordEngagementsIfEnabled(frameIds: [frameId], nowMs: nowMs)
    }

    package func recordImpression(frameId: UInt64) async {
        await recordImpressions(frameIds: [frameId])
    }

    package func recordImpressions(frameIds: [UInt64]) async {
        let nowMs = config.rag.deterministicNowMs ?? nowProvider()
        await recordImpressionsIfEnabled(frameIds: frameIds, nowMs: nowMs)
    }

    package func seedAccessStats(frameId: UInt64, from stats: FrameAccessStats) async {
        guard config.enableAccessStatsScoring else { return }
        await accessStatsManager.seedStats(stats, for: frameId)
    }

    private func dedupedExplanations(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(reasons.count)
        for reason in reasons {
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    package func sessionRuntimeStats() async throws -> SessionRuntimeStats {
        try await sessionRuntimeStats(sessionId: currentSessionId)
    }

    package func sessionRuntimeStats(sessionId: UUID?) async throws -> SessionRuntimeStats {
        let storeStats = await wax.stats()
        let pendingFramesStoreWide = storeStats.pendingFrames
        guard let sessionId else {
            return SessionRuntimeStats(
                active: false,
                sessionId: nil,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let frameIds = await wax.activeFrameIDs(
            matchingMetadataKey: "session_id",
            value: sessionId.uuidString
        )

        guard !frameIds.isEmpty else {
            sessionRuntimeStatsCache[sessionId] = nil
            return SessionRuntimeStats(
                active: true,
                sessionId: sessionId,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        if let cached = sessionRuntimeStatsCache[sessionId],
           cached.generation == storeStats.generation,
           cached.frameIds == frameIds {
            return SessionRuntimeStats(
                active: true,
                sessionId: sessionId,
                sessionFrameCount: frameIds.count,
                sessionTokenEstimate: cached.tokenEstimate,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let frameMetas = await wax.frameMetas(frameIds: frameIds)
        var textsByFrameID: [UInt64: String] = [:]
        textsByFrameID.reserveCapacity(frameIds.count)
        var missingSearchTextFrameIDs: [UInt64] = []
        missingSearchTextFrameIDs.reserveCapacity(frameIds.count)

        for frameId in frameIds {
            if let searchText = frameMetas[frameId]?.searchText {
                textsByFrameID[frameId] = searchText
            } else {
                missingSearchTextFrameIDs.append(frameId)
            }
        }

        if !missingSearchTextFrameIDs.isEmpty {
            let contentMap = try await wax.frameContents(frameIds: missingSearchTextFrameIDs)
            for frameId in missingSearchTextFrameIDs {
                guard let data = contentMap[frameId],
                      let text = String(data: data, encoding: .utf8) else {
                    continue
                }
                textsByFrameID[frameId] = text
            }
        }

        let texts = frameIds.compactMap { textsByFrameID[$0] }
        let tokenCounter = try await TokenCounter.shared()
        let tokenCounts = await tokenCounter.countBatch(texts)
        let totalTokens = tokenCounts.reduce(0, +)
        sessionRuntimeStatsCache[sessionId] = SessionRuntimeStatsCacheEntry(
            generation: storeStats.generation,
            frameIds: frameIds,
            tokenEstimate: totalTokens
        )

        return SessionRuntimeStats(
            active: true,
            sessionId: sessionId,
            sessionFrameCount: frameIds.count,
            sessionTokenEstimate: totalTokens,
            pendingFramesStoreWide: pendingFramesStoreWide,
            countsIncludePending: false
        )
    }

    private func ragConfigForRecall() -> FastRAGConfig {
        var recallConfig = config.rag
        if recallConfig.deterministicNowMs == nil {
            recallConfig.deterministicNowMs = nowProvider()
        }
        return recallConfig
    }

    private func extractTemporalTimeRange(from query: String, anchorMs: Int64?) -> SearchTimeRange? {
        guard let anchorMs else { return nil }
        let anchor = Date(timeIntervalSince1970: Double(anchorMs) / 1000.0)
        let normalizer = TemporalNormalizer(anchor: anchor)
        let words = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        for window in stride(from: min(4, words.count), through: 1, by: -1) {
            guard words.count >= window else { continue }
            for i in 0...(words.count - window) {
                let candidate = words[i..<(i + window)].joined(separator: " ")
                guard let resolution = try? normalizer.resolve(candidate) else { continue }
                let range = resolution.asTimeRange
                return SearchTimeRange(after: range.afterMs, before: range.beforeMs)
            }
        }
        return nil
    }

    package func rememberHandoff(
        content: String,
        project: String? = nil,
        pendingTasks: [String] = [],
        sessionId: UUID? = nil,
        commit: Bool = true
    ) async throws -> UInt64 {
        try await handoffWriteMutex.withLock { [self] in
            try await rememberHandoffSerialized(
                content: content,
                project: project,
                pendingTasks: pendingTasks,
                sessionId: sessionId,
                commit: commit
            )
        }
    }

    private func rememberHandoffSerialized(
        content: String,
        project: String?,
        pendingTasks: [String],
        sessionId: UUID?,
        commit: Bool
    ) async throws -> UInt64 {
        let pending = pendingTasks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedProject = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSessionId = sessionId ?? currentSessionId
        let previous: FrameMeta? = if let normalizedProject,
                                      !normalizedProject.isEmpty,
                                      let effectiveSessionId {
            await wax.latestActiveHandoffMeta(
                project: normalizedProject,
                matchingSessionId: effectiveSessionId.uuidString
            )
        } else {
            nil
        }
        let searchText = ([content] + pending).joined(separator: "\n")

        var metadata = Metadata()
        metadata.entries["kind"] = "handoff"
        metadata.entries[MemoryMetadataKeys.type] = MemoryType.handoff.rawValue
        metadata.entries[MemoryMetadataKeys.durability] = MemoryDurability.ephemeral.rawValue
        metadata.entries[MemoryMetadataKeys.createdAtMs] = String(Int64(Date().timeIntervalSince1970 * 1000))
        if let normalizedProject, !normalizedProject.isEmpty {
            metadata.entries["project"] = normalizedProject
            metadata.entries[MemoryMetadataKeys.project] = normalizedProject
        }
        if !pending.isEmpty {
            metadata.entries["pending_tasks"] = pending.joined(separator: "\n")
        }
        if let effectiveSessionId {
            metadata.entries["session_id"] = effectiveSessionId.uuidString
        }

        let frameId = try await session.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                kind: FrameKind.handoff.storageValue,
                labels: ["handoff"],
                role: .document,
                searchText: searchText,
                metadata: metadata
            )
        )
        if config.enableTextSearch {
            try await session.indexText(frameId: frameId, text: searchText)
        }
        if let previous, previous.id != frameId {
            try await wax.supersede(supersededId: previous.id, supersedingId: frameId)
        }
        // Ensure latestHandoff() can observe this frame immediately when commit=true.
        if commit {
            try await session.commit()
        }
        return frameId
    }

    package func latestHandoff(project: String? = nil) async throws -> HandoffRecord? {
        guard let latest = await wax.latestCommittedActiveHandoffMeta(project: project) else {
            return nil
        }

        let payload = try await wax.frameContent(frameId: latest.id)
        guard let content = String(data: payload, encoding: .utf8) else {
            throw WaxError.decodingError(reason: "handoff payload is not UTF-8")
        }
        let metadata = latest.metadata?.entries ?? [:]
        let pendingTasks = metadata["pending_tasks"]?
            .split(separator: "\n")
            .map { String($0) } ?? []

        return HandoffRecord(
            frameId: latest.id,
            timestampMs: latest.timestamp,
            content: content,
            project: metadata["project"],
            pendingTasks: pendingTasks
        )
    }

    package func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String] = [],
        commit: Bool = true
    ) async throws -> EntityRowID {
        try ensureStructuredMemoryEnabled()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let entityID = try await session.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs)
        if commit {
            try await session.commit()
        }
        return entityID
    }

    package func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        relation: VersionRelation = .sets,
        validFromMs: Int64? = nil,
        validToMs: Int64? = nil,
        evidence: [StructuredEvidence] = [],
        commit: Bool = true
    ) async throws -> FactRowID {
        try ensureStructuredMemoryEnabled()
        let nowMs = try nextStructuredSystemMs()
        let valid = StructuredTimeRange(fromMs: validFromMs ?? nowMs, toMs: validToMs)
        let system = StructuredTimeRange(fromMs: nowMs, toMs: nil)
        let factID = try await session.assertFact(
            subject: subject,
            predicate: predicate,
            object: object,
            relation: relation,
            valid: valid,
            system: system,
            evidence: evidence
        )
        if commit {
            try await session.commit()
        }
        return factID
    }

    package func retractFact(factId: FactRowID, atMs: Int64? = nil, commit: Bool = true) async throws {
        try ensureStructuredMemoryEnabled()
        let timestamp = try atMs ?? nextStructuredSystemMs()
        try await session.retractFact(factId: factId, atMs: timestamp)
        if commit {
            try await session.commit()
        }
    }

    private func nextStructuredSystemMs() throws -> Int64 {
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        guard wallNow < Int64.max else {
            throw WaxError.encodingError(reason: "structured system timestamp must be less than Int64.max")
        }
        guard let last = lastStructuredSystemMs, wallNow <= last else {
            lastStructuredSystemMs = wallNow
            return wallNow
        }

        let next = last.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue < Int64.max else {
            throw WaxError.encodingError(reason: "structured system timestamp overflow")
        }
        lastStructuredSystemMs = next.partialValue
        return next.partialValue
    }

    private func executeRecall(
        query: String,
        frameFilter: FrameFilter?,
        timeRange: SearchTimeRange?,
        topK: Int?,
        requestedMode: SearchMode?
    ) async throws -> RecallExecution {
        let recallConfig = ragConfigForRecall()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let implicitExactIntent = requestedMode == nil
            && RuleBasedQueryClassifier.isExactIntentQuery(trimmedQuery)
        let resolvedRequestedMode = requestedMode
            ?? (implicitExactIntent ? .textOnly : recallConfig.searchMode)
        let embeddingPolicy: QueryEmbeddingPolicy = if let requestedMode {
            Self.queryEmbeddingPolicy(for: requestedMode)
        } else if implicitExactIntent {
            .never
        } else {
            .ifAvailable
        }
        guard !trimmedQuery.isEmpty else {
            return RecallExecution(
                context: RAGContext(query: query, items: [], totalTokens: 0),
                requestedMode: resolvedRequestedMode,
                effectiveMode: resolvedRequestedMode,
                queryEmbeddingState: .notRequested
            )
        }

        let attached = readyEmbedderSnapshot
        if let hold = searchSnapshotHoldForTesting {
            try await Task.sleep(for: hold)
        }
        let queryEmbedding = try await queryEmbeddingResult(
            for: trimmedQuery,
            policy: embeddingPolicy,
            attached: attached
        )
        let effectiveSearchMode = try Self.resolveSearchMode(
            requested: resolvedRequestedMode,
            embeddingAvailable: queryEmbedding.embedding != nil
        )

        let context = try await buildRecallContext(
            query: trimmedQuery,
            embedding: queryEmbedding.embedding,
            frameFilter: frameFilter,
            timeRange: timeRange,
            searchTopK: topK,
            searchMode: effectiveSearchMode
        )

        return RecallExecution(
            context: context,
            requestedMode: resolvedRequestedMode,
            effectiveMode: effectiveSearchMode,
            queryEmbeddingState: queryEmbedding.state
        )
    }

    private struct QueryEmbeddingResult {
        let embedding: [Float]?
        let state: RAGContext.QueryEmbeddingState
    }

    private static func queryEmbeddingPolicy(for mode: SearchMode) -> QueryEmbeddingPolicy {
        switch mode {
        case .textOnly:
            .never
        case .vectorOnly:
            .always
        case .hybrid:
            .ifAvailable
        }
    }

    private static func resolveSearchMode(requested: SearchMode, embeddingAvailable: Bool) throws -> SearchMode {
        switch requested {
        case .textOnly:
            .textOnly
        case .vectorOnly where !embeddingAvailable:
            throw WaxError.missingEmbedder
        case .vectorOnly:
            .vectorOnly
        case .hybrid where !embeddingAvailable:
            .textOnly
        case .hybrid(let alpha):
            .hybrid(alpha: SearchMode.clampHybridAlpha(alpha))
        }
    }

    package func facts(
        about subject: EntityKey? = nil,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> StructuredFactsResult {
        try ensureStructuredMemoryEnabled()
        return try await session.facts(
            about: subject,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(
                systemTimeMs: systemAsOfMs ?? asOfMs,
                validTimeMs: validAsOfMs ?? asOfMs
            ),
            limit: limit
        )
    }

    package func edges(
        for entity: EntityKey,
        direction: StructuredEdgeDirection,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> StructuredEdgesResult {
        try ensureStructuredMemoryEnabled()
        return try await session.edges(
            for: entity,
            direction: direction,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(
                systemTimeMs: systemAsOfMs ?? asOfMs,
                validTimeMs: validAsOfMs ?? asOfMs
            ),
            limit: limit
        )
    }

    package func resolveEntities(matchingAlias alias: String, limit: Int = 10) async throws -> [StructuredEntityMatch] {
        try ensureStructuredMemoryEnabled()
        return try await session.resolveEntities(matchingAlias: alias, limit: limit)
    }

    package func entity(forKey key: EntityKey) async throws -> StructuredEntityMatch? {
        try ensureStructuredMemoryEnabled()
        return try await session.entity(forKey: key)
    }

    // MARK: - Delete

    /// Soft-deletes a frame and removes it from text/vector indexes when those features are enabled.
    ///
    /// Matches ``FrameStore/delete(frameID:)`` durability (delete + commit) while also cleaning
    /// search indexes so forgotten content is not returned by subsequent recalls.
    ///
    /// Soft-delete is pending until a single commit after index removes, so the committed vector
    /// (and text) indexes exclude the deleted frame without a second commit or close-time flush.
    /// If index remove throws, the soft-delete is not committed in this call.
    package func delete(frameId: UInt64) async throws {
        lastWriteActivityAt = .now

        try await wax.delete(frameId: frameId)

        if config.enableTextSearch {
            try await session.removeText(frameId: frameId)
        }
        if config.enableVectorSearch {
            try await session.removeVector(frameId: frameId)
        }
        try await session.commit()
    }

    // MARK: - Persistence lifecycle

    package func flush() async throws {
        try await flushMutex.withLock { [self] in
            try await flushSerialized()
        }
    }

    private func flushSerialized() async throws {
        if let enrichmentPipeline {
            let drained = try await enrichmentPipeline.waitUntilIdle(
                bestEffortTimeout: config.enrichmentFlushDrainTimeout
            )
            if !drained {
                WaxDiagnostics.logSwallowed(
                    WaxError.io("enrichment drain timed out before flush"),
                    context: "enrichment flush drain timeout",
                    fallback: "continuing flush with pending enrichment work"
                )
            }
        }
        if config.enableAccessStatsScoring {
            try await persistAccessStatsIfNeeded()
        }
        try await session.commit()
        flushCount &+= 1
        enqueueScheduledLiveSetMaintenance()
    }

    package func close() async throws {
        isClosed = true
        readinessFollowTask?.cancel()
        readinessFollowTask = nil
        try await flush()
        if let enrichmentPipeline {
            do {
                try await enrichmentPipeline.stop(timeout: config.enrichmentStopTimeout)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "enrichment stop during close",
                    fallback: "continuing close after cancelling enrichment worker"
                )
            }
        }
        let sourceURL = await wax.fileURL()
        let maintenanceReport = await closeTimeLiveSetMaintenanceReport()
        await session.close()
        try await wax.close()
        if let maintenanceReport {
            do {
                try Self.promoteValidatedLiveSetCandidateIfNeeded(
                    maintenanceReport,
                    sourceURL: sourceURL
                )
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "close-time live-set candidate promotion",
                    fallback: "source store left unchanged; validated candidate retained"
                )
            }
        }
    }

    func enrichmentStatsForTesting() async -> EnrichmentPipeline.Stats? {
        guard let enrichmentPipeline else { return nil }
        return await enrichmentPipeline.stats
    }

    package func scheduledLiveSetMaintenanceReport() -> ScheduledLiveSetMaintenanceReport? {
        lastScheduledLiveSetMaintenanceReport
    }

    private func enqueueScheduledLiveSetMaintenance() {
        guard config.liveSetRewriteSchedule.enabled else { return }
        scheduledLiveSetMaintenanceQueued = true
        guard scheduledLiveSetMaintenanceTask == nil else { return }

        scheduledLiveSetMaintenanceTask = Task(priority: .utility) { [self] in
            await drainScheduledLiveSetMaintenanceQueue()
        }
    }

    private func drainScheduledLiveSetMaintenanceQueue() async {
        while scheduledLiveSetMaintenanceQueued {
            scheduledLiveSetMaintenanceQueued = false
            let triggerFlushCount = flushCount
            do {
                if let report = try await runScheduledLiveSetMaintenanceIfNeeded(
                    flushCount: triggerFlushCount,
                    force: false,
                    triggeredByFlush: true
                ) {
                    lastScheduledLiveSetMaintenanceReport = report
                }
            } catch {
                lastScheduledLiveSetMaintenanceReport = ScheduledLiveSetMaintenanceReport(
                    outcome: .rewriteFailed,
                    triggeredByFlush: true,
                    flushCount: triggerFlushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["scheduled maintenance task failed: \(error)"]
                )
            }
        }

        scheduledLiveSetMaintenanceTask = nil
        if scheduledLiveSetMaintenanceQueued {
            enqueueScheduledLiveSetMaintenance()
        }
    }

    private func closeTimeLiveSetMaintenanceReport() async -> ScheduledLiveSetMaintenanceReport? {
        let schedule = config.liveSetRewriteSchedule
        guard schedule.enabled else {
            if let task = scheduledLiveSetMaintenanceTask {
                await task.value
            }
            return lastScheduledLiveSetMaintenanceReport
        }

        if schedule.promoteValidatedCandidateOnClose {
            do {
                let report = try await runScheduledLiveSetMaintenanceNow()
                lastScheduledLiveSetMaintenanceReport = report
                return report
            } catch {
                let report = ScheduledLiveSetMaintenanceReport(
                    outcome: .rewriteFailed,
                    triggeredByFlush: false,
                    flushCount: flushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["close-time maintenance failed: \(error)"]
                )
                lastScheduledLiveSetMaintenanceReport = report
                return report
            }
        }

        if let task = scheduledLiveSetMaintenanceTask {
            await task.value
        }
        return lastScheduledLiveSetMaintenanceReport
    }

    // MARK: - Math helpers

    /// L2 normalization using Accelerate framework for optimal SIMD performance.
    @inline(__always)
    private static func normalizedL2(_ vector: [Float]) -> [Float] {
        VectorMath.normalizeL2(vector)
    }

    private static func writeEmbeddings(_ embeddings: [[Float]], to url: URL) throws {
        var data = Data()
        data.reserveCapacity(8 + embeddings.reduce(0) { $0 + ($1.count * 4) })

        var count = UInt32(embeddings.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for vector in embeddings {
            guard vector.count <= Int(UInt32.max) else {
                throw WaxError.encodingError(reason: "embedding dimension exceeds UInt32.max")
            }
            var dimension = UInt32(vector.count).littleEndian
            withUnsafeBytes(of: &dimension) { data.append(contentsOf: $0) }
            for value in vector {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }

        try data.write(to: url, options: .atomic)
    }

    private static func readEmbeddings(from url: URL) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        var offset = 0

        func readUInt32() throws -> UInt32 {
            guard data.count - offset >= 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { destination in
                data.copyBytes(to: destination, from: offset..<(offset + 4))
            }
            let value = UInt32(littleEndian: raw)
            offset += 4
            return value
        }

        let count = try Int(readUInt32())
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(count)

        for _ in 0..<count {
            let dimension = try Int(readUInt32())
            guard dimension >= 0 else {
                throw WaxError.decodingError(reason: "invalid embedding dimension")
            }
            guard data.count - offset >= dimension * 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var vector: [Float] = []
            vector.reserveCapacity(dimension)
            for _ in 0..<dimension {
                var raw: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &raw) { destination in
                    data.copyBytes(to: destination, from: offset..<(offset + 4))
                }
                let bits = UInt32(littleEndian: raw)
                vector.append(Float(bitPattern: bits))
                offset += 4
            }
            embeddings.append(vector)
        }

        guard offset == data.count else {
            throw WaxError.decodingError(reason: "invalid embedding batch payload trailing bytes")
        }

        return embeddings
    }

    #if DEBUG
    private final class DebugCounterState: @unchecked Sendable {
        let lock = NSLock()
        var batchPreparationPathCallCounts: [String: Int] = [:]
        var memoryBindingEnsureCallCounts: [String: Int] = [:]
    }

    private static let debugCounterState = DebugCounterState()
    @TaskLocal private static var activeDebugCounterScopeKey: String?

    package static func _recordBatchPreparationPathCallForTests() {
        debugCounterState.lock.lock()
        let key = activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.batchPreparationPathCallCounts[key, default: 0] += 1
        debugCounterState.lock.unlock()
    }

    package static func _withIsolatedDebugCountersForTests<T: Sendable>(
        _ body: @Sendable (String) async throws -> T
    ) async rethrows -> T {
        let key = UUID().uuidString
        return try await $activeDebugCounterScopeKey.withValue(key) {
            try await body(key)
        }
    }

    package static func _resetBatchPreparationPathCallCountForTests(scopeKey: String? = nil) {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.batchPreparationPathCallCounts[key] = 0
        debugCounterState.lock.unlock()
    }

    package static func _batchPreparationPathCallCountForTests(scopeKey: String? = nil) -> Int {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        let count = debugCounterState.batchPreparationPathCallCounts[key, default: 0]
        debugCounterState.lock.unlock()
        return count
    }

    package static func _recordMemoryBindingEnsureCallForTests() {
        debugCounterState.lock.lock()
        let key = activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.memoryBindingEnsureCallCounts[key, default: 0] += 1
        debugCounterState.lock.unlock()
    }

    package static func _resetMemoryBindingEnsureCallCountForTests(scopeKey: String? = nil) {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.memoryBindingEnsureCallCounts[key] = 0
        debugCounterState.lock.unlock()
    }

    package static func _memoryBindingEnsureCallCountForTests(scopeKey: String? = nil) -> Int {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        let count = debugCounterState.memoryBindingEnsureCallCounts[key, default: 0]
        debugCounterState.lock.unlock()
        return count
    }

    package static func _writeEmbeddingsForTesting(_ embeddings: [[Float]], to url: URL) throws {
        try writeEmbeddings(embeddings, to: url)
    }

    package static func _readEmbeddingsForTesting(from url: URL) throws -> [[Float]] {
        try readEmbeddings(from: url)
    }
    #endif

    private func queryEmbedding(for query: String, policy: QueryEmbeddingPolicy) async throws -> [Float]? {
        return try await queryEmbeddingResult(
            for: query,
            policy: policy,
            attached: readyEmbedderSnapshot
        ).embedding
    }

    package func followReadiness(_ session: EmbeddingReadinessSession) {
        readinessFollowTask?.cancel()
        readinessFollowTask = Task {
            let result = await session.waitUntilCompileFinished()
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let provider):
                await self.attachEmbedder(provider)
            case .failure(let error):
                self.markUnavailable(error.localizedDescription)
            }
        }
    }

    package func attachEmbedder(_ provider: any EmbeddingProvider) async {
        guard !isClosed else { return }
        if config.requireOnDeviceProviders {
            do {
                try ProviderValidation.validateOnDevice(
                    [.init(name: "embedding provider", executionMode: provider.executionMode)],
                    orchestratorName: "MemoryOrchestrator"
                )
            } catch {
                markUnavailable(error.localizedDescription)
                return
            }
        }
        let binding = await wax.memoryBinding()
        guard !isClosed else { return }
        if let binding, !binding.isEmpty {
            guard let identity = provider.identity else {
                markUnavailable("memory binding requires an identifiable embedder provider")
                return
            }
            guard MemoryBindingCompatibility.isCompatible(binding, with: identity) else {
                let mismatch = MemoryBindingCompatibility.mismatchReason(binding, with: identity) ?? "unknown mismatch"
                markUnavailable("memory binding mismatch with embedder identity (\(mismatch))")
                return
            }
        }
        if config.enableVectorSearch {
            do {
                try await session.ensureVectorEngine(dimensions: provider.dimensions)
            } catch {
                markUnavailable(error.localizedDescription)
                return
            }
        }
        guard !isClosed else { return }
        if embeddingCache == nil {
            embeddingCache = EmbeddingMemoizer.fromConfig(
                capacity: config.embeddingCacheCapacity,
                enabled: true
            )
        }
        let lacksVectors: Bool
        if case .loading(true) = embedderLifecycle {
            lacksVectors = true
        } else {
            lacksVectors = await Self.storeHasUnembeddedChunks(wax)
        }
        guard !isClosed else { return }
        embedderLifecycle = .ready(
            attached: AttachedEmbedder(provider: provider),
            degradedReason: lacksVectors ? "some saved frames have no vectors" : nil
        )
    }

    package func markUnavailable(_ reason: String) {
        embedderLifecycle = .unavailable(reason: reason)
    }

    package func markUnavailableIfStillLoading(_ reason: String) {
        guard case .loading = embedderLifecycle else { return }
        embedderLifecycle = .unavailable(reason: reason)
    }

    private static func storeHasUnembeddedChunks(_ wax: Wax) async -> Bool {
        await framesWithoutVectorsCount(wax) > 0
    }

    private static func framesWithoutVectorsCount(_ wax: Wax) async -> UInt64 {
        UInt64((await unembeddedLiveSources(in: wax)).count)
    }

    private func unembeddedLiveSources() async -> [SurrogateSourceFrame] {
        await Self.unembeddedLiveSources(in: wax)
    }

    private static func unembeddedLiveSources(in wax: Wax) async -> [SurrogateSourceFrame] {
        let sources = await wax.activeSurrogateSourceFrames()
        let embedded = await embeddedFrameIds(in: wax)
        return sources.filter { !embedded.contains($0.id) }
    }

    private static func embeddedFrameIds(in wax: Wax) async -> Set<UInt64> {
        var ids = Set<UInt64>()
        for pending in await wax.pendingEmbeddingMutations() {
            ids.insert(pending.frameId)
        }
        if let staged = await wax.readStagedVecIndexBytes() {
            ids.formUnion(Self.vecSegmentFrameIds(bytes: staged.bytes))
        }
        if let bytes = try? await wax.readCommittedVecIndexBytes() {
            ids.formUnion(Self.vecSegmentFrameIds(bytes: bytes))
        }
        return ids
    }

    private func refreshEmbeddingCoverage() async {
        guard case .ready(let attached, _) = embedderLifecycle else {
            return
        }
        let lacksVectors = await Self.storeHasUnembeddedChunks(wax)
        embedderLifecycle = .ready(
            attached: attached,
            degradedReason: lacksVectors ? "some saved frames have no vectors" : nil
        )
    }

    private func queryEmbeddingResult(
        for query: String,
        policy: QueryEmbeddingPolicy,
        attached: AttachedEmbedder?
    ) async throws -> QueryEmbeddingResult {
        switch policy {
        case .never:
            return QueryEmbeddingResult(embedding: nil, state: .notRequested)
        case .ifAvailable:
            guard config.enableVectorSearch else {
                return QueryEmbeddingResult(embedding: nil, state: .vectorDisabled)
            }
            guard let attached else {
                return QueryEmbeddingResult(embedding: nil, state: .noEmbedder)
            }
            guard !queryEmbeddingCircuitOpen else {
                return QueryEmbeddingResult(embedding: nil, state: .circuitOpen)
            }
            do {
                let embedding = try await Self.embedOne(
                    query,
                    attached: attached,
                    cache: embeddingCache,
                    timeout: config.queryEmbeddingTimeout,
                    isQuery: true
                )
                queryEmbeddingCircuitOpenedAtMs = nil
                return QueryEmbeddingResult(embedding: embedding, state: .available)
            } catch {
                if error is AsyncTimeout.TimeoutError {
                    queryEmbeddingCircuitOpenedAtMs = nowProvider()
                    return QueryEmbeddingResult(embedding: nil, state: .timeout)
                }
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "query embedding",
                    fallback: "text-only search for this query"
                )
                return QueryEmbeddingResult(embedding: nil, state: .failed)
            }
        case .always:
            guard config.enableVectorSearch else {
                throw WaxError.featureDisabled(feature: "vector search")
            }
            guard let attached else {
                throw WaxError.missingEmbedder
            }
            guard !queryEmbeddingCircuitOpen else {
                throw WaxError.io("query embedding paused after timeout; retries automatically after cooldown")
            }
            do {
                let embedding = try await Self.embedOne(
                    query,
                    attached: attached,
                    cache: embeddingCache,
                    timeout: config.queryEmbeddingTimeout,
                    isQuery: true
                )
                queryEmbeddingCircuitOpenedAtMs = nil
                return QueryEmbeddingResult(embedding: embedding, state: .available)
            } catch {
                if error is AsyncTimeout.TimeoutError {
                    queryEmbeddingCircuitOpenedAtMs = nowProvider()
                }
                throw error
            }
        }
    }

    private static func embedOne(
        _ text: String,
        attached: AttachedEmbedder,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil,
        isQuery: Bool = false
    ) async throws -> [Float] {
        let embedder = attached.provider
        let queryAware = isQuery ? attached.queryAware : nil
        let useQueryEmbed = queryAware != nil
        let key = EmbeddingKey.make(
            text: text,
            identity: embedder.identity,
            dimensions: embedder.dimensions,
            normalized: embedder.normalize,
            queryAware: useQueryEmbed
        )
        if let cached = await cache?.get(key) {
            return cached
        }

        var vector: [Float]
        if let timeout {
            vector = try await AsyncTimeout.run(timeout: timeout, operation: "embedder.embed") {
                if let queryAware {
                    return try await queryAware.embedQuery(text)
                }
                return try await embedder.embed(text)
            }
        } else if let queryAware {
            vector = try await queryAware.embedQuery(text)
        } else {
            vector = try await embedder.embed(text)
        }
        if embedder.normalize {
            vector = normalizedL2(vector)
        }
        await cache?.set(key, value: vector)
        return vector
    }

    private static func prepareEmbeddings(
        chunks: [String],
        attached: AttachedEmbedder,
        cache: EmbeddingMemoizer?
    ) async throws -> [Int: [Float]] {
        let embedder = attached.provider
        var out: [Int: [Float]] = [:]
        out.reserveCapacity(chunks.count)

        var missingTexts: [String] = []
        var missingIndices: [Int] = []
        missingTexts.reserveCapacity(chunks.count)
        missingIndices.reserveCapacity(chunks.count)

        for (idx, chunk) in chunks.enumerated() {
            let key = EmbeddingKey.make(
                text: chunk,
                identity: embedder.identity,
                dimensions: embedder.dimensions,
                normalized: embedder.normalize
            )
            if let cached = await cache?.get(key) {
                out[idx] = cached
            } else {
                missingTexts.append(chunk)
                missingIndices.append(idx)
            }
        }

        if missingTexts.isEmpty {
            return out
        }

        if let batch = attached.batch {
            let vectors = try await batch.embed(batch: missingTexts)
            guard vectors.count == missingTexts.count else {
                throw WaxError.io("batch embedding count mismatch: expected \(missingTexts.count), got \(vectors.count)")
            }
            for (position, idx) in missingIndices.enumerated() {
                var vector = vectors[position]
                if embedder.normalize {
                    vector = normalizedL2(vector)
                }
                out[idx] = vector
                let key = EmbeddingKey.make(
                    text: chunks[idx],
                    identity: embedder.identity,
                    dimensions: embedder.dimensions,
                    normalized: embedder.normalize
                )
                await cache?.set(key, value: vector)
            }
        } else {
            for (position, idx) in missingIndices.enumerated() {
                let chunk = missingTexts[position]
                let vector = try await embedOne(
                    chunk,
                    attached: attached,
                    cache: cache
                )
                out[idx] = vector
            }
        }

        return out
    }

    private func ensureStructuredMemoryEnabled() throws {
        guard config.enableStructuredMemory else {
            throw WaxError.featureDisabled(feature: "structured memory")
        }
    }

    private func recordAccessesIfEnabled(frameIds: [UInt64], nowMs: Int64) async {
        await recordEngagementsIfEnabled(frameIds: frameIds, nowMs: nowMs)
    }

    private func recordEngagementsIfEnabled(frameIds: [UInt64], nowMs: Int64) async {
        guard config.enableAccessStatsScoring, !frameIds.isEmpty else { return }
        await accessStatsManager.recordAccesses(frameIds: frameIds, nowMs: nowMs)
    }

    private func recordImpressionsIfEnabled(frameIds: [UInt64], nowMs: Int64) async {
        guard config.enableAccessStatsScoring, !frameIds.isEmpty else { return }
        await accessStatsManager.recordImpressions(frameIds: frameIds, nowMs: nowMs)
    }

    private func loadPersistedAccessStatsIfNeeded() async throws {
        guard let latest = await wax.latestCommittedActiveSystemFrameMeta(
            kind: Self.accessStatsFrameKind,
            fallbackMetadataKey: Self.accessStatsMarkerKey,
            fallbackMetadataValue: Self.accessStatsMarkerValue
        ) else {
            return
        }

        let payload = try await wax.frameContent(frameId: latest.id)
        do {
            let imported = try JSONDecoder().decode([FrameAccessStats].self, from: payload)
            await accessStatsManager.importStats(imported)
            accessStatsFrameId = latest.id
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "access stats import",
                fallback: "starting with empty access stats"
            )
        }
    }

    private func persistAccessStatsIfNeeded() async throws {
        guard let snapshot = await accessStatsManager.exportStatsSnapshotIfDirty() else {
            return
        }
        if let hold = accessStatsPersistenceHoldForTesting {
            try await Task.sleep(for: hold)
        }
        let exported = snapshot.stats
        guard !exported.isEmpty else {
            _ = await accessStatsManager.markPersisted(ifRevision: snapshot.revision)
            return
        }
        let payload = try JSONEncoder().encode(exported)

        var metadata = Metadata()
        metadata.entries[Self.accessStatsMarkerKey] = Self.accessStatsMarkerValue
        let frameId = try await session.put(
            payload,
            options: FrameMetaSubset(
                kind: Self.accessStatsFrameKind,
                labels: [Self.accessStatsLabel],
                role: .system,
                metadata: metadata
            )
        )
        let previousFrameId = accessStatsFrameId
        // Update the tracked frame ID before superseding so that if supersede throws,
        // the next flush will still attempt to supersede this frame rather than
        // the pre-supersede frame, preventing orphaned stats frames from accumulating.
        accessStatsFrameId = frameId
        if let previous = previousFrameId, previous != frameId {
            do {
                try await wax.supersede(supersededId: previous, supersedingId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "access stats supersede",
                    fallback: "previous stats frame may remain active until next flush"
                )
            }
        }
        // A get/promote may have recorded newer accesses while the WAL writes
        // above awaited. Only acknowledge the revision we actually persisted;
        // a newer revision remains dirty for the next flush.
        _ = await accessStatsManager.markPersisted(ifRevision: snapshot.revision)
    }
}
