import Foundation
import WaxCore
import WaxVectorSearch

package extension MemoryOrchestrator {
    // MARK: - Recall (Fast RAG)

    /// Precomputed-embedding recall path (does not run query embedding).
    package func recall(query: String, embedding: [Float]) async throws -> RAGContext {
        try await buildRecallContext(query: query, embedding: embedding)
    }

    package func recall(
        query: String,
        embeddingPolicy: QueryEmbeddingPolicy = .ifAvailable,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        topK: Int? = nil,
        mode: DirectSearchMode? = nil
    ) async throws -> RAGContext {
        try await executeRecall(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: frameFilter,
            timeRange: timeRange,
            topK: topK,
            requestedMode: mode
        ).context
    }

    package func recallExecution(
        query: String,
        embeddingPolicy: QueryEmbeddingPolicy = .ifAvailable,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        topK: Int? = nil,
        mode: DirectSearchMode? = nil
    ) async throws -> RecallExecution {
        try await executeRecall(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: frameFilter,
            timeRange: timeRange,
            topK: topK,
            requestedMode: mode
        )
    }

    /// Shared recall implementation: builds the RAG context and records frame accesses.
    /// All package recall() overloads funnel through here so that `ragConfigForRecall()` and
    /// `recordAccessesIfEnabled` cannot diverge between overloads in future edits.
    func buildRecallContext(
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
        let context = try await ragBuilder.build(
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
        let accessStatsMap: [UInt64: FrameAccessStats] = if config.enableAccessStatsScoring {
            await accessStatsManager.getStats(frameIds: context.items.map(\.frameId))
        } else {
            [:]
        }
        let enrichedItems = context.items.map { item in
            var item = item
            let accessReasons = MemorySemantics.accessReasons(stats: accessStatsMap[item.frameId]).reasons
            if !accessReasons.isEmpty {
                item.explanations = dedupedExplanations(item.explanations + accessReasons)
            }
            return item
        }
        await recordAccessesIfEnabled(frameIds: context.items.map(\.frameId))
        return RAGContext(query: context.query, items: enrichedItems, totalTokens: context.totalTokens)
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
        mode: DirectSearchMode = .default,
        topK: Int = 10,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil
    ) async throws -> SearchExecution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedModeSummary = Self.modeSummary(mode)
        guard !trimmed.isEmpty else {
            return SearchExecution(
                hits: [],
                requestedModeSummary: requestedModeSummary,
                effectiveModeSummary: "text",
                queryEmbeddingState: .notRequested
            )
        }
        guard topK > 0 else {
            return SearchExecution(
                hits: [],
                requestedModeSummary: requestedModeSummary,
                effectiveModeSummary: "text",
                queryEmbeddingState: .notRequested
            )
        }

        let preference = config.vectorEnginePreference

        let policy: QueryEmbeddingPolicy = switch mode {
        case .text:
            .never
        case .vector:
            .always
        case .hybrid:
            .ifAvailable
        }
        let queryEmbedding = try await queryEmbeddingResult(for: trimmed, policy: policy)
        let searchMode = Self.resolveSearchMode(
            requested: Self.searchMode(from: mode),
            embeddingAvailable: queryEmbedding.embedding != nil
        )

        let request = SearchRequest(
            query: trimmed,
            embedding: queryEmbedding.embedding,
            vectorEnginePreference: preference,
            vectorSearchTimeout: config.vectorSearchTimeout,
            mode: searchMode,
            topK: topK,
            timeRange: timeRange,
            frameFilter: frameFilter,
            scopeContext: config.defaultScopeContext,
            previewMaxBytes: config.rag.previewMaxBytes
        )
        let response = try await session.search(request)

        let accessStatsMap: [UInt64: FrameAccessStats] = if config.enableAccessStatsScoring {
            await accessStatsManager.getStats(frameIds: response.results.map(\.frameId))
        } else {
            [:]
        }
        let hits = response.results.map { result in
            let accessReasons = MemorySemantics.accessReasons(stats: accessStatsMap[result.frameId]).reasons
            return MemorySearchHit(
                frameId: result.frameId,
                score: result.score,
                previewText: result.previewText,
                sources: result.sources,
                metadata: result.metadata,
                explanations: dedupedExplanations(result.explanations + accessReasons)
            )
        }
        await recordAccessesIfEnabled(frameIds: hits.map(\.frameId))
        return SearchExecution(
            hits: hits,
            requestedModeSummary: requestedModeSummary,
            effectiveModeSummary: Self.modeSummary(searchMode),
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
            queryEmbedderConfigured: embedder != nil,
            queryEmbeddingCircuitOpen: queryEmbeddingCircuitOpen,
            structuredMemoryEnabled: config.enableStructuredMemory,
            accessStatsScoringEnabled: config.enableAccessStatsScoring,
            embedderIdentity: embedder?.identity
        )
    }

    package func accessStatsSnapshot() async -> [UInt64: FrameAccessStats] {
        await accessStatsManager.snapshot()
    }

    func dedupedExplanations(_ reasons: [String]) -> [String] {
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

    func ragConfigForRecall() -> FastRAGConfig {
        var recallConfig = config.rag
        if recallConfig.deterministicNowMs == nil {
            recallConfig.deterministicNowMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        return recallConfig
    }

    func extractTemporalTimeRange(from query: String, anchorMs: Int64?) -> SearchTimeRange? {
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

    func executeRecall(
        query: String,
        embeddingPolicy: QueryEmbeddingPolicy,
        frameFilter: FrameFilter?,
        timeRange: SearchTimeRange?,
        topK: Int?,
        requestedMode: DirectSearchMode?
    ) async throws -> RecallExecution {
        let recallConfig = ragConfigForRecall()
        let requestedSearchMode = requestedMode.map(Self.searchMode(from:)) ?? recallConfig.searchMode
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            let modeSummary = Self.modeSummary(requestedSearchMode)
            return RecallExecution(
                context: RAGContext(query: query, items: [], totalTokens: 0),
                requestedModeSummary: modeSummary,
                effectiveModeSummary: modeSummary,
                queryEmbeddingState: .notRequested
            )
        }

        let queryEmbedding = try await queryEmbeddingResult(for: trimmedQuery, policy: embeddingPolicy)
        let effectiveSearchMode = Self.resolveSearchMode(
            requested: requestedSearchMode,
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
            requestedModeSummary: requestedMode.map(Self.modeSummary) ?? Self.modeSummary(requestedSearchMode),
            effectiveModeSummary: Self.modeSummary(effectiveSearchMode),
            queryEmbeddingState: queryEmbedding.state
        )
    }

    struct QueryEmbeddingResult {
        let embedding: [Float]?
        let state: QueryEmbeddingState
    }

    static func searchMode(from mode: DirectSearchMode) -> SearchMode {
        switch mode {
        case .text:
            .textOnly
        case .vector:
            .vectorOnly
        case .hybrid(let alpha):
            .hybrid(alpha: clampHybridAlpha(alpha))
        }
    }

    static func resolveSearchMode(requested: SearchMode, embeddingAvailable: Bool) -> SearchMode {
        switch requested {
        case .textOnly:
            .textOnly
        case .vectorOnly where !embeddingAvailable:
            .textOnly
        case .vectorOnly:
            .vectorOnly
        case .hybrid where !embeddingAvailable:
            .textOnly
        case .hybrid(let alpha):
            .hybrid(alpha: clampHybridAlpha(alpha))
        }
    }

    static func modeSummary(_ mode: SearchMode) -> String {
        switch mode {
        case .textOnly:
            return "text"
        case .vectorOnly:
            return "vector"
        case .hybrid(let alpha):
            return "hybrid(alpha=\(String(format: "%.3f", Double(alpha))))"
        }
    }

    static func modeSummary(_ mode: DirectSearchMode) -> String {
        switch mode {
        case .text:
            return "text"
        case .vector:
            return "vector"
        case .hybrid(let alpha):
            return "hybrid(alpha=\(String(format: "%.3f", Double(alpha))))"
        }
    }

    func queryEmbedding(for query: String, policy: QueryEmbeddingPolicy) async throws -> [Float]? {
        try await queryEmbeddingResult(for: query, policy: policy).embedding
    }

    func queryEmbeddingResult(
        for query: String,
        policy: QueryEmbeddingPolicy
    ) async throws -> QueryEmbeddingResult {
        switch policy {
        case .never:
            return QueryEmbeddingResult(embedding: nil, state: .notRequested)
        case .ifAvailable:
            guard config.enableVectorSearch else {
                return QueryEmbeddingResult(embedding: nil, state: .vectorDisabled)
            }
            guard let embedder else {
                return QueryEmbeddingResult(embedding: nil, state: .noEmbedder)
            }
            guard !queryEmbeddingCircuitOpen else {
                return QueryEmbeddingResult(embedding: nil, state: .circuitOpen)
            }
            do {
                let embedding = try await Self.embedOne(
                    query,
                    embedder: embedder,
                    cache: embeddingCache,
                    timeout: config.queryEmbeddingTimeout,
                    isQuery: true
                )
                queryEmbeddingCircuitOpenedAt = nil
                return QueryEmbeddingResult(embedding: embedding, state: .available)
            } catch {
                if error is AsyncTimeout.TimeoutError {
                    queryEmbeddingCircuitOpenedAt = .now
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
                throw WaxError.io("query embedding requested but vector search is disabled")
            }
            guard let embedder else {
                throw WaxError.io("query embedding requested but no EmbeddingProvider configured")
            }
            guard !queryEmbeddingCircuitOpen else {
                throw WaxError.io("query embedding paused after timeout; retries automatically after cooldown")
            }
            do {
                let embedding = try await Self.embedOne(
                    query,
                    embedder: embedder,
                    cache: embeddingCache,
                    timeout: config.queryEmbeddingTimeout,
                    isQuery: true
                )
                queryEmbeddingCircuitOpenedAt = nil
                return QueryEmbeddingResult(embedding: embedding, state: .available)
            } catch {
                if error is AsyncTimeout.TimeoutError {
                    queryEmbeddingCircuitOpenedAt = .now
                }
                throw error
            }
        }
    }

    static func embedOne(
        _ text: String,
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil,
        isQuery: Bool = false
    ) async throws -> [Float] {
        // Use query-aware embedding when available and this is a recall/query path.
        let useQueryEmbed = isQuery && (embedder is any QueryAwareEmbeddingProvider)
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
                if useQueryEmbed, let qa = embedder as? any QueryAwareEmbeddingProvider {
                    return try await qa.embedQuery(text)
                }
                return try await embedder.embed(text)
            }
        } else {
            if useQueryEmbed, let qa = embedder as? any QueryAwareEmbeddingProvider {
                vector = try await qa.embedQuery(text)
            } else {
                vector = try await embedder.embed(text)
            }
        }
        if embedder.normalize {
            vector = normalizedL2(vector)
        }
        await cache?.set(key, value: vector)
        return vector
    }

    static func prepareEmbeddings(
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

}
