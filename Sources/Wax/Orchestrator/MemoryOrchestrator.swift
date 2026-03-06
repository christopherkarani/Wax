import Foundation
import WaxCore
import WaxVectorSearch

/// High-level orchestrator for text memory RAG, managing ingest, recall, and lifecycle on a Wax store.
package actor MemoryOrchestrator {
    /// Policy controlling when to compute query embeddings for vector search.
    package enum QueryEmbeddingPolicy: Sendable, Equatable {
        case never
        case ifAvailable
        case always
    }

    /// Direct search mode for raw candidate retrieval.
    package enum DirectSearchMode: Sendable, Equatable {
        case text
        case hybrid(alpha: Float)

        package static let `default`: DirectSearchMode = .hybrid(alpha: 0.5)
    }

    /// Stable search hit DTO for MCP and other raw-search callers.
    package struct MemorySearchHit: Sendable, Equatable {
        package var frameId: UInt64
        package var score: Float
        package var previewText: String?
        package var sources: [SearchResponse.Source]

        package init(frameId: UInt64, score: Float, previewText: String?, sources: [SearchResponse.Source]) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
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
        package var structuredMemoryEnabled: Bool
        package var accessStatsScoringEnabled: Bool
        package var embedderIdentity: EmbeddingIdentity?

        package init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            generation: UInt64,
            wal: WaxWALStats,
            storeURL: URL,
            vectorSearchEnabled: Bool,
            structuredMemoryEnabled: Bool,
            accessStatsScoringEnabled: Bool,
            embedderIdentity: EmbeddingIdentity?
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.generation = generation
            self.wal = wal
            self.storeURL = storeURL
            self.vectorSearchEnabled = vectorSearchEnabled
            self.structuredMemoryEnabled = structuredMemoryEnabled
            self.accessStatsScoringEnabled = accessStatsScoringEnabled
            self.embedderIdentity = embedderIdentity
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

    private static let accessStatsFrameKind = "wax.internal.access_stats"
    private static let accessStatsLabel = "wax.internal"
    private static let accessStatsMarkerKey = "wax.internal.kind"
    private static let accessStatsMarkerValue = "access_stats"
    private static let contentHashMetadataKey = "wax.content.hash"

    let wax: Wax
    let config: OrchestratorConfig
    private let ragBuilder: FastRAGContextBuilder

    let session: WaxSession
    private let embedder: (any EmbeddingProvider)?
    private let embeddingCache: EmbeddingMemoizer?
    private let enrichmentPipeline: EnrichmentPipeline?
    private let accessStatsManager = AccessStatsManager()
    private var accessStatsFrameId: UInt64?
    private var queryEmbeddingCircuitOpen = false

    private var currentSessionId: UUID?
    var flushCount: UInt64 = 0
    var lastWriteActivityAt: ContinuousClock.Instant = .now
    var lastScheduledLiveSetMaintenanceReport: ScheduledLiveSetMaintenanceReport?
    var scheduledLiveSetMaintenanceTask: Task<Void, Never>?
    var scheduledLiveSetMaintenanceQueued = false
    var scheduledLiveSetMaintenanceLastCompletedAt: ContinuousClock.Instant?

    package init(
        at url: URL,
        config: OrchestratorConfig = .default
    ) async throws {
        try await self.init(at: url, config: config, embedder: nil)
    }

    package init(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil
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
            self.wax = try await Wax.open(at: url)
        } else {
            self.wax = try await Wax.create(at: url)
        }

        // Auto-disable vector search when no embedder is provided and no pre-existing
        // vector index exists. This lets the simple `MemoryOrchestrator(at:)` initializer
        // work out-of-the-box with text-only search instead of throwing an error.
        var resolvedConfig = config
        if resolvedConfig.enableVectorSearch, embedder == nil, await wax.committedVecIndexManifest() == nil {
            resolvedConfig.enableVectorSearch = false
        }
        if let identity = embedder?.identity,
           let binding = await wax.memoryBinding(),
           !MemoryBindingCompatibility.isCompatible(binding, with: identity) {
            let mismatch = MemoryBindingCompatibility.mismatchReason(binding, with: identity) ?? "unknown mismatch"
            try? await wax.close()
            throw WaxError.io("memory binding mismatch with embedder identity (\(mismatch))")
        }

        self.config = resolvedConfig
        self.ragBuilder = FastRAGContextBuilder()
        self.embedder = embedder
        self.embeddingCache = EmbeddingMemoizer.fromConfig(
            capacity: resolvedConfig.embeddingCacheCapacity,
            enabled: embedder != nil
        )
        self.enrichmentPipeline = resolvedConfig.enableAsyncEnrichment ? EnrichmentPipeline() : nil

        let preference: VectorEnginePreference = resolvedConfig.useMetalVectorSearch ? .metalPreferred : .cpuOnly
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
            await enrichmentPipeline.start { task in
                EnrichmentResult(
                    frameId: task.frameId,
                    keywords: KeywordExtractor.extract(from: task.text),
                    entities: []
                )
            }
        }
        if resolvedConfig.enableAccessStatsScoring {
            try await loadPersistedAccessStatsIfNeeded()
        }
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
    package func remember(_ content: String, metadata: [String: String] = [:]) async throws {
        lastWriteActivityAt = .now
        let contentData = Data(content.utf8)
        let contentHash = ContentHasher.hash(contentData).hexString
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        let localEmbedder = embedder

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
        ), existingProbe.isComplete {
            return
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
            _ = try await localSession.put(
                contentData,
                options: FrameMetaSubset(
                    role: .document,
                    metadata: docMeta
                )
            )
            return
        }

        if useVectorSearch, localEmbedder == nil {
            throw WaxError.io("enableVectorSearch=true requires an EmbeddingProvider for ingest-time embeddings")
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

        var preparedEmbeddingsByBatch: [Int: [[Float]]] = [:]
        preparedEmbeddingsByBatch.reserveCapacity(batchRanges.count)
        var preparedBatchCount = 0

        try await withThrowingTaskGroup(of: IngestBatchResult.self) { group in
            func enqueue(_ entry: (index: Int, range: Range<Int>)) {
                group.addTask {
                    let batchChunks = Array(chunks[entry.range])

                    if let localEmbedder = localEmbedder, useVectorSearch {
                        let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
                            chunks: batchChunks,
                            embedder: localEmbedder,
                            cache: cache
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
        if useVectorSearch, preparedEmbeddingsByBatch.count != batchRanges.count {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) prepared embedding batches, got \(preparedEmbeddingsByBatch.count)"
            )
        }
        var didSetMemoryBinding = false

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

            if useVectorSearch {
                guard let embeddings = preparedEmbeddingsByBatch[entry.index] else {
                    throw WaxError.io("missing prepared embeddings for batch \(entry.index)")
                }
                let frameIds = try await localSession.putBatch(
                    contents: batchContents,
                    embeddings: embeddings,
                    identity: localEmbedder?.identity,
                    options: options
                )
                if !didSetMemoryBinding, let binding = bindingForEmbedderIdentity {
                    try await wax.setMemoryBindingIfMissing(binding)
                    didSetMemoryBinding = true
                }

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

    /// Optimized batch embedding preparation with cache-aware batching.
    /// Minimizes cache lookups and maximizes batch embedding efficiency.
    private static func prepareEmbeddingsBatchOptimized(
        chunks: [String],
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [[Float]] {
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
            
            // Prefer batch embedding for significantly better throughput
            if let batchEmbedder = embedder as? any BatchEmbeddingProvider {
                // Use optimized batch embedding - 3-8x faster than sequential
                vectors = try await batchEmbedder.embed(batch: missingTexts)
            } else {
                var sequentialVectors: [[Float]] = []
                sequentialVectors.reserveCapacity(missingTexts.count)
                for text in missingTexts {
                    let vector = try await embedder.embed(text)
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
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [[Float]] {
        try await prepareEmbeddingsBatchOptimized(chunks: chunks, embedder: embedder, cache: cache)
    }

    // MARK: - Recall (Fast RAG)

    package func recall(query: String) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: .ifAvailable)
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    package func recall(query: String, frameFilter: FrameFilter?) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: .ifAvailable)
        return try await buildRecallContext(query: query, embedding: embedding, frameFilter: frameFilter)
    }

    package func recall(query: String, embedding: [Float]) async throws -> RAGContext {
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    package func recall(query: String, embeddingPolicy: QueryEmbeddingPolicy) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: embeddingPolicy)
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    package func recall(
        query: String,
        embeddingPolicy: QueryEmbeddingPolicy,
        frameFilter: FrameFilter?,
        timeRange: SearchTimeRange?,
        topK: Int?,
        mode: DirectSearchMode?
    ) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: embeddingPolicy)

        let searchModeOverride: SearchMode? = if let mode {
            switch mode {
            case .text:
                .textOnly
            case .hybrid(let alpha):
                if embedding == nil {
                    .textOnly
                } else {
                    .hybrid(alpha: Self.clampHybridAlpha(alpha))
                }
            }
        } else {
            nil
        }

        return try await buildRecallContext(
            query: query,
            embedding: embedding,
            frameFilter: frameFilter,
            timeRange: timeRange,
            searchTopK: topK,
            searchMode: searchModeOverride
        )
    }

    /// Shared recall implementation: builds the RAG context and records frame accesses.
    /// All package recall() overloads funnel through here so that `ragConfigForRecall()` and
    /// `recordAccessesIfEnabled` cannot diverge between overloads in future edits.
    private func buildRecallContext(
        query: String,
        embedding: [Float]?,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        searchTopK: Int? = nil,
        searchMode: SearchMode? = nil
    ) async throws -> RAGContext {
        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
        var recallConfig = ragConfigForRecall()
        if let searchTopK {
            recallConfig.searchTopK = max(1, searchTopK)
        }
        if let searchMode {
            recallConfig.searchMode = searchMode
        }
        let resolvedTimeRange = timeRange ?? extractTemporalTimeRange(from: query, anchorMs: recallConfig.deterministicNowMs)
        let context = try await ragBuilder.build(
            query: query,
            embedding: embedding,
            vectorEnginePreference: preference,
            wax: wax,
            session: session,
            frameFilter: frameFilter,
            timeRange: resolvedTimeRange,
            accessStatsManager: config.enableAccessStatsScoring ? accessStatsManager : nil,
            config: recallConfig
        )
        await recordAccessesIfEnabled(frameIds: context.items.map(\.frameId))
        return context
    }

    /// Performs direct search without context assembly.
    ///
    /// - Parameters:
    ///   - query: Query text.
    ///   - mode: Text-only or hybrid retrieval.
    ///   - topK: Maximum number of hits to return.
    /// - Returns: Ranked raw hits.
    package func search(
        query: String,
        mode: DirectSearchMode = .default,
        topK: Int = 10,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil
    ) async throws -> [MemorySearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard topK > 0 else { return [] }

        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly

        let policy: QueryEmbeddingPolicy = switch mode {
        case .text:
            .never
        case .hybrid:
            .ifAvailable
        }
        let embedding = try await queryEmbedding(for: trimmed, policy: policy)

        let searchMode: SearchMode = switch mode {
        case .text:
            .textOnly
        case .hybrid(let alpha):
            if embedding == nil {
                .textOnly
            } else {
                .hybrid(alpha: Self.clampHybridAlpha(alpha))
            }
        }

        let request = SearchRequest(
            query: trimmed,
            embedding: embedding,
            vectorEnginePreference: preference,
            vectorSearchTimeout: config.vectorSearchTimeout,
            mode: searchMode,
            topK: topK,
            timeRange: timeRange,
            frameFilter: frameFilter,
            previewMaxBytes: config.rag.previewMaxBytes
        )
        let response = try await session.search(request)

        let hits = response.results.map { result in
            MemorySearchHit(
                frameId: result.frameId,
                score: result.score,
                previewText: result.previewText,
                sources: result.sources
            )
        }
        await recordAccessesIfEnabled(frameIds: hits.map(\.frameId))
        return hits
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
            structuredMemoryEnabled: config.enableStructuredMemory,
            accessStatsScoringEnabled: config.enableAccessStatsScoring,
            embedderIdentity: embedder?.identity
        )
    }

    package func sessionRuntimeStats() async throws -> SessionRuntimeStats {
        let pendingFramesStoreWide = await wax.stats().pendingFrames
        guard let sessionId = currentSessionId else {
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
            return SessionRuntimeStats(
                active: true,
                sessionId: sessionId,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let contentMap = try await wax.frameContents(frameIds: frameIds)
        let texts: [String] = frameIds.compactMap { frameId in
            guard let data = contentMap[frameId] else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let tokenCounter = try await TokenCounter.shared()
        let tokenCounts = await tokenCounter.countBatch(texts)
        let totalTokens = tokenCounts.reduce(0, +)

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
            recallConfig.deterministicNowMs = Int64(Date().timeIntervalSince1970 * 1000)
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
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = pendingTasks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let text: String
        if pending.isEmpty {
            text = normalizedContent
        } else {
            let items = pending.map { "- \($0)" }.joined(separator: "\n")
            text = """
            \(normalizedContent)

            Pending tasks:
            \(items)
            """
        }

        var metadata = Metadata()
        metadata.entries["kind"] = "handoff"
        if let project, !project.isEmpty {
            metadata.entries["project"] = project
        }
        if !pending.isEmpty {
            metadata.entries["pending_tasks"] = pending.joined(separator: "\n")
        }
        if let effectiveSessionId = sessionId ?? currentSessionId {
            metadata.entries["session_id"] = effectiveSessionId.uuidString
        }

        let frameId = try await session.put(
            Data(text.utf8),
            options: FrameMetaSubset(
                kind: "handoff",
                labels: ["handoff"],
                role: .document,
                searchText: text,
                metadata: metadata
            )
        )
        if config.enableTextSearch {
            try await session.indexText(frameId: frameId, text: text)
        }
        // Ensure latestHandoff() can observe this frame immediately when commit=true.
        if commit {
            try await session.commit()
        }
        return frameId
    }

    package func latestHandoff(project: String? = nil) async throws -> HandoffRecord? {
        let metas = await wax.frameMetas()
        let filtered = metas.filter { meta in
            guard meta.status == .active, meta.supersededBy == nil else { return false }
            let hasHandoffKind = meta.kind == "handoff" || meta.metadata?.entries["kind"] == "handoff"
            let hasHandoffLabel = meta.labels.contains("handoff")
            guard hasHandoffKind || hasHandoffLabel else { return false }
            if let project, !project.isEmpty {
                return meta.metadata?.entries["project"] == project
            }
            return true
        }

        guard let latest = filtered.max(by: { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id < rhs.id
            }
            return lhs.timestamp < rhs.timestamp
        }) else {
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
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
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
        let timestamp = atMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        try await session.retractFact(factId: factId, atMs: timestamp)
        if commit {
            try await session.commit()
        }
    }

    package func facts(
        about subject: EntityKey? = nil,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        limit: Int = 50
    ) async throws -> StructuredFactsResult {
        try ensureStructuredMemoryEnabled()
        return try await session.facts(
            about: subject,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(asOfMs: asOfMs),
            limit: limit
        )
    }

    package func resolveEntities(matchingAlias alias: String, limit: Int = 10) async throws -> [StructuredEntityMatch] {
        try ensureStructuredMemoryEnabled()
        return try await session.resolveEntities(matchingAlias: alias, limit: limit)
    }

    // MARK: - Persistence lifecycle

    package func flush() async throws {
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

    @inline(__always)
    private static func clampHybridAlpha(_ alpha: Float) -> Float {
        guard alpha.isFinite else { return 0.5 }
        return min(1, max(0, alpha))
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
    package static func _writeEmbeddingsForTesting(_ embeddings: [[Float]], to url: URL) throws {
        try writeEmbeddings(embeddings, to: url)
    }

    package static func _readEmbeddingsForTesting(from url: URL) throws -> [[Float]] {
        try readEmbeddings(from: url)
    }
    #endif

    private func queryEmbedding(for query: String, policy: QueryEmbeddingPolicy) async throws -> [Float]? {
        switch policy {
        case .never:
            return nil
        case .ifAvailable:
            guard config.enableVectorSearch, let embedder else { return nil }
            guard !queryEmbeddingCircuitOpen else { return nil }
            do {
                return try await Self.embedOne(
                    query,
                    embedder: embedder,
                    cache: embeddingCache,
                    timeout: config.queryEmbeddingTimeout
                )
            } catch {
                if error is AsyncTimeout.TimeoutError {
                    queryEmbeddingCircuitOpen = true
                }
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "query embedding",
                    fallback: "text-only search for this query"
                )
                return nil
            }
        case .always:
            guard config.enableVectorSearch else {
                throw WaxError.io("query embedding requested but vector search is disabled")
            }
            guard let embedder else {
                throw WaxError.io("query embedding requested but no EmbeddingProvider configured")
            }
            guard !queryEmbeddingCircuitOpen else {
                throw WaxError.io("query embedding disabled after timeout; restart to retry")
            }
            do {
                return try await Self.embedOne(
                    query,
                    embedder: embedder,
                    cache: embeddingCache,
                    timeout: config.queryEmbeddingTimeout
                )
            } catch {
                if error is AsyncTimeout.TimeoutError {
                    queryEmbeddingCircuitOpen = true
                }
                throw error
            }
        }
    }

    private static func embedOne(
        _ text: String,
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [Float] {
        let key = EmbeddingKey.make(
            text: text,
            identity: embedder.identity,
            dimensions: embedder.dimensions,
            normalized: embedder.normalize
        )
        if let cached = await cache?.get(key) {
            return cached
        }

        var vector: [Float]
        if let timeout {
            vector = try await AsyncTimeout.run(timeout: timeout, operation: "embedder.embed") {
                try await embedder.embed(text)
            }
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
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [Int: [Float]] {
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

        if let batch = embedder as? any BatchEmbeddingProvider {
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
                let vector = try await embedOne(chunk, embedder: embedder, cache: cache)
                out[idx] = vector
            }
        }

        return out
    }

    private func ensureStructuredMemoryEnabled() throws {
        guard config.enableStructuredMemory else {
            throw WaxError.io("structured memory is disabled")
        }
    }

    private func recordAccessesIfEnabled(frameIds: [UInt64]) async {
        guard config.enableAccessStatsScoring, !frameIds.isEmpty else { return }
        await accessStatsManager.recordAccesses(frameIds: frameIds)
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
        guard let exported = await accessStatsManager.exportStatsIfDirty() else {
            return
        }
        guard !exported.isEmpty else {
            await accessStatsManager.markPersisted()
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
        await accessStatsManager.markPersisted()
    }
}
