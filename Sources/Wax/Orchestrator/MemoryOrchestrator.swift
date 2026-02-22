import Foundation
import WaxCore
import WaxVectorSearch

/// High-level orchestrator for text memory RAG, managing ingest, recall, and lifecycle on a Wax store.
public actor MemoryOrchestrator {
    /// Policy controlling when to compute query embeddings for vector search.
    public enum QueryEmbeddingPolicy: Sendable, Equatable {
        case never
        case ifAvailable
        case always
    }

    /// Direct search mode for raw candidate retrieval.
    public enum DirectSearchMode: Sendable, Equatable {
        case text
        case hybrid(alpha: Float)

        public static let `default`: DirectSearchMode = .hybrid(alpha: 0.5)
    }

    /// Stable search hit DTO for MCP and other raw-search callers.
    public struct MemorySearchHit: Sendable, Equatable {
        public var frameId: UInt64
        public var score: Float
        public var previewText: String?
        public var sources: [SearchResponse.Source]

        public init(frameId: UInt64, score: Float, previewText: String?, sources: [SearchResponse.Source]) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
        }
    }

    /// Runtime stats DTO exposed to external callers.
    public struct RuntimeStats: Sendable, Equatable {
        public var frameCount: UInt64
        public var pendingFrames: UInt64
        public var generation: UInt64
        public var wal: WaxWALStats
        public var storeURL: URL
        public var vectorSearchEnabled: Bool
        public var structuredMemoryEnabled: Bool
        public var accessStatsScoringEnabled: Bool
        public var embedderIdentity: EmbeddingIdentity?

        public init(
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

    public struct SessionRuntimeStats: Sendable, Equatable {
        public var active: Bool
        public var sessionId: UUID?
        public var sessionFrameCount: Int
        public var sessionTokenEstimate: Int
        public var pendingFramesStoreWide: UInt64
        public var countsIncludePending: Bool

        public init(
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

    public struct HandoffRecord: Sendable, Equatable {
        public var frameId: UInt64
        public var timestampMs: Int64
        public var content: String
        public var project: String?
        public var pendingTasks: [String]

        public init(frameId: UInt64, timestampMs: Int64, content: String, project: String?, pendingTasks: [String]) {
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

    let wax: Wax
    let config: OrchestratorConfig
    private let ragBuilder: FastRAGContextBuilder

    let session: WaxSession
    private let embedder: (any EmbeddingProvider)?
    private let embeddingCache: EmbeddingMemoizer?
    private let accessStatsManager = AccessStatsManager()
    private var accessStatsFrameId: UInt64?

    private var currentSessionId: UUID?
    var flushCount: UInt64 = 0
    var lastWriteActivityAt: ContinuousClock.Instant = .now
    var lastScheduledLiveSetMaintenanceReport: ScheduledLiveSetMaintenanceReport?
    var scheduledLiveSetMaintenanceTask: Task<Void, Never>?
    var scheduledLiveSetMaintenanceQueued = false
    var scheduledLiveSetMaintenanceLastCompletedAt: ContinuousClock.Instant?

    public init(
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

        self.config = resolvedConfig
        self.ragBuilder = FastRAGContextBuilder()
        self.embedder = embedder
        self.embeddingCache = EmbeddingMemoizer.fromConfig(
            capacity: resolvedConfig.embeddingCacheCapacity,
            enabled: embedder != nil
        )

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
        if resolvedConfig.enableAccessStatsScoring {
            try await loadPersistedAccessStatsIfNeeded()
        }
    }


    // MARK: - Session tagging (v1)

    public func startSession() -> UUID {
        let id = UUID()
        currentSessionId = id
        return id
    }

    public func endSession() {
        currentSessionId = nil
    }

    public func activeSessionId() -> UUID? {
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
    public func remember(_ content: String, metadata: [String: String] = [:]) async throws {
        lastWriteActivityAt = .now
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        var docMeta = Metadata(metadata)
        if docMeta.entries["session_id"] == nil, let session = currentSessionId {
            docMeta.entries["session_id"] = session.uuidString
        }
        let effectiveSessionId = docMeta.entries["session_id"]

        let chunkCount = chunks.count
        let localSession = session
        let localEmbedder = embedder
        let cache = embeddingCache
        let batchSize = max(1, config.ingestBatchSize)
        let useVectorSearch = config.enableVectorSearch
        let fileManager = FileManager.default

        guard !chunks.isEmpty else {
            _ = try await localSession.put(
                Data(content.utf8),
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

        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("wax-ingest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        if useVectorSearch {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        }

        var stagedEmbeddingFiles: [Int: URL] = [:]
        stagedEmbeddingFiles.reserveCapacity(batchRanges.count)
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
                    let fileURL = stagingDirectory.appendingPathComponent("batch-\(result.index).emb")
                    try Self.writeEmbeddings(embeddings, to: fileURL)
                    stagedEmbeddingFiles[result.index] = fileURL
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
        if useVectorSearch, stagedEmbeddingFiles.count != batchRanges.count {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) staged embedding batches, got \(stagedEmbeddingFiles.count)"
            )
        }

        let docId = try await localSession.put(
            Data(content.utf8),
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
                guard let fileURL = stagedEmbeddingFiles[entry.index] else {
                    throw WaxError.io("missing staged embeddings for batch \(entry.index)")
                }
                let embeddings = try Self.readEmbeddings(from: fileURL)
                let frameIds = try await localSession.putBatch(
                    contents: batchContents,
                    embeddings: embeddings,
                    identity: localEmbedder?.identity,
                    options: options
                )

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
            } else {
                let frameIds = try await localSession.putBatch(contents: batchContents, options: options)

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
            }
        }
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

    public func recall(query: String) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: .ifAvailable)
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    public func recall(query: String, frameFilter: FrameFilter?) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: .ifAvailable)
        return try await buildRecallContext(query: query, embedding: embedding, frameFilter: frameFilter)
    }

    public func recall(query: String, embedding: [Float]) async throws -> RAGContext {
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    public func recall(query: String, embeddingPolicy: QueryEmbeddingPolicy) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: embeddingPolicy)
        return try await buildRecallContext(query: query, embedding: embedding)
    }

    /// Shared recall implementation: builds the RAG context and records frame accesses.
    /// All public recall() overloads funnel through here so that `ragConfigForRecall()` and
    /// `recordAccessesIfEnabled` cannot diverge between overloads in future edits.
    private func buildRecallContext(
        query: String,
        embedding: [Float]?,
        frameFilter: FrameFilter? = nil
    ) async throws -> RAGContext {
        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
        let recallConfig = ragConfigForRecall()
        let context = try await ragBuilder.build(
            query: query,
            embedding: embedding,
            vectorEnginePreference: preference,
            wax: wax,
            session: session,
            frameFilter: frameFilter,
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
    public func search(
        query: String,
        mode: DirectSearchMode = .default,
        topK: Int = 10,
        frameFilter: FrameFilter? = nil
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
            mode: searchMode,
            topK: topK,
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
    public func runtimeStats() async -> RuntimeStats {
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

    public func sessionRuntimeStats() async throws -> SessionRuntimeStats {
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

        let metas = await wax.frameMetas()
        let matching = metas.filter { meta in
            guard meta.status == .active, meta.supersededBy == nil else { return false }
            return meta.metadata?.entries["session_id"] == sessionId.uuidString
        }

        guard !matching.isEmpty else {
            return SessionRuntimeStats(
                active: true,
                sessionId: sessionId,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let frameIds = matching.map(\.id)
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
            sessionFrameCount: matching.count,
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

    public func rememberHandoff(
        content: String,
        project: String? = nil,
        pendingTasks: [String] = [],
        sessionId: UUID? = nil
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
        // Ensure latestHandoff() can observe this frame immediately via committed metadata/content views.
        try await session.commit()
        return frameId
    }

    public func latestHandoff(project: String? = nil) async throws -> HandoffRecord? {
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

    public func upsertEntity(
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

    public func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
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
            valid: valid,
            system: system,
            evidence: evidence
        )
        if commit {
            try await session.commit()
        }
        return factID
    }

    public func retractFact(factId: FactRowID, atMs: Int64? = nil, commit: Bool = true) async throws {
        try ensureStructuredMemoryEnabled()
        let timestamp = atMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        try await session.retractFact(factId: factId, atMs: timestamp)
        if commit {
            try await session.commit()
        }
    }

    public func facts(
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

    public func resolveEntities(matchingAlias alias: String, limit: Int = 10) async throws -> [StructuredEntityMatch] {
        try ensureStructuredMemoryEnabled()
        return try await session.resolveEntities(matchingAlias: alias, limit: limit)
    }

    // MARK: - Persistence lifecycle

    public func flush() async throws {
        if config.enableAccessStatsScoring {
            try await persistAccessStatsIfNeeded()
        }
        try await session.commit()
        flushCount &+= 1
        enqueueScheduledLiveSetMaintenance()
    }

    public func close() async throws {
        try await flush()
        if let task = scheduledLiveSetMaintenanceTask {
            await task.value
        }
        await session.close()
        try await wax.close()
    }

    public func scheduledLiveSetMaintenanceReport() -> ScheduledLiveSetMaintenanceReport? {
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
            return try await Self.embedOne(query, embedder: embedder, cache: embeddingCache)
        case .always:
            guard config.enableVectorSearch else {
                throw WaxError.io("query embedding requested but vector search is disabled")
            }
            guard let embedder else {
                throw WaxError.io("query embedding requested but no EmbeddingProvider configured")
            }
            return try await Self.embedOne(query, embedder: embedder, cache: embeddingCache)
        }
    }

    private static func embedOne(
        _ text: String,
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
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

        var vector = try await embedder.embed(text)
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
        let metas = await wax.frameMetas()
        let candidates = metas.filter { meta in
            guard meta.status == .active, meta.supersededBy == nil, meta.role == .system else { return false }
            if meta.kind == Self.accessStatsFrameKind {
                return true
            }
            return meta.metadata?.entries[Self.accessStatsMarkerKey] == Self.accessStatsMarkerValue
        }
        guard let latest = candidates.max(by: { $0.timestamp < $1.timestamp }) else { return }

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
