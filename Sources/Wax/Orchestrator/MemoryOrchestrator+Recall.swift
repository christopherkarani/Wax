import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// Policy controlling when to compute query embeddings for vector search.
    private enum QueryEmbeddingPolicy: Sendable, Equatable {
        case never
        case ifAvailable
        case always
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
        topK: Int? = nil,
        scopeContext: MemoryScopeContext? = nil,
        maxContextTokens: Int? = nil,
        inferTimeRange: Bool = true
    ) async throws -> RecallExecution {
        try await executeRecall(
            query: query,
            frameFilter: frameFilter,
            timeRange: timeRange,
            topK: topK,
            requestedMode: mode,
            scopeContext: scopeContext,
            maxContextTokens: maxContextTokens,
            inferTimeRange: inferTimeRange
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
        searchMode: SearchMode? = nil,
        scopeContext: MemoryScopeContext? = nil,
        maxContextTokens: Int? = nil,
        inferTimeRange: Bool = true
    ) async throws -> RAGContext {
        let preference = config.vectorEnginePreference
        var recallConfig = ragConfigForRecall()
        if let searchTopK {
            recallConfig.searchTopK = max(1, searchTopK)
        }
        if let searchMode {
            recallConfig.searchMode = searchMode
        }
        if let maxContextTokens {
            // A caller-sized budget should be able to hold every requested hit.
            recallConfig.maxContextTokens = maxContextTokens
            recallConfig.maxSnippets = max(recallConfig.maxSnippets, recallConfig.searchTopK)
        }
        // An inferred range filters on save time, so only past-looking phrases
        // apply (see `pastIngestTimeRange`). An explicit range always wins.
        let inferredTimeRange: SearchTimeRange? = if timeRange == nil, inferTimeRange {
            Self.pastIngestTimeRange(inferredFrom: query, anchorMs: recallConfig.deterministicNowMs)
        } else {
            nil
        }
        // Access reasons are attached once during pack. Do not re-fetch stats
        // or re-append the same strings here.
        var context = try await ragBuilder.build(
            query: query,
            embedding: embedding,
            vectorEnginePreference: preference,
            vectorSearchTimeout: config.vectorSearchTimeout,
            wax: wax,
            session: session,
            frameFilter: frameFilter,
            timeRange: timeRange ?? inferredTimeRange,
            scopeContext: scopeContext ?? config.defaultScopeContext,
            accessStatsManager: config.enableAccessStatsScoring ? accessStatsManager : nil,
            reranking: config.reranking,
            config: recallConfig
        )
        if let inferredTimeRange {
            context.diagnostics?.inferredTimeRange = Memory.TimeRange(
                afterMs: inferredTimeRange.after,
                beforeMs: inferredTimeRange.before
            )
        }
        return context
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
                diagnostics: .text(requested: mode, embedding: .notRequested)
            )
        }
        guard topK > 0 else {
            return SearchExecution(
                hits: [],
                diagnostics: .text(requested: mode, embedding: .notRequested)
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
        let lane = try SearchLane.from(mode: searchMode, embedding: queryEmbedding.embedding)

        // Access-aware ranking needs additional candidates so a stale top hit
        // can be displaced by a close, recently/frequently used result. The
        // candidate window is bounded and applies only when the feature is on.
        let accessEnabled = config.enableAccessStatsScoring
        let searchTopK = AccessRankingWindow.candidateCount(
            requestedTopK: topK,
            accessEnabled: accessEnabled,
            multiplier: 3,
            applyWhenRequestedTopKAtMost: 16
        )
        // One ranking-now for this search: UnifiedSearch recency and later
        // access ranking must not tick the wall clock twice.
        let searchNowMs = config.rag.deterministicNowMs ?? nowProvider()
        let request = try SearchRequest(
            query: trimmed,
            lane: lane,
            vectorEnginePreference: preference,
            vectorSearchTimeout: config.vectorSearchTimeout,
            topK: searchTopK,
            timeRange: timeRange,
            frameFilter: frameFilter,
            nowMs: searchNowMs,
            scopeContext: config.defaultScopeContext,
            previewMaxBytes: config.rag.previewMaxBytes
        )
        let response = try await session.search(request)

        let accessStatsMap: [UInt64: FrameAccessStats] = if accessEnabled {
            await AccessFrequencyRanker.statsForRanking(
                frameIds: response.results.map(\.frameId),
                manager: accessStatsManager,
                wax: wax
            )
        } else {
            [:]
        }
        let scoredResults = RankedSearch.applyAccessRanking(
            results: response.results,
            query: trimmed,
            accessStats: accessStatsMap,
            nowMs: searchNowMs,
            maxWindow: searchTopK,
            enabled: accessEnabled
        )
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
            diagnostics: Self.retrievalDiagnostics(
                requested: mode,
                effective: response.vectorSearchTimedOut ? .textOnly : searchMode,
                embedding: queryEmbedding.state
            )
        )
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

    private func ragConfigForRecall() -> FastRAGConfig {
        var recallConfig = config.rag
        if recallConfig.deterministicNowMs == nil {
            recallConfig.deterministicNowMs = nowProvider()
        }
        return recallConfig
    }

    /// Save-time filter inferred from a temporal phrase in the query.
    ///
    /// Frames carry their save (ingest) timestamp, never their event date. A
    /// phrase whose window starts at or after `anchorMs` ("tomorrow", "next
    /// week") describes event time, so filtering on save time would always be
    /// empty; those phrases are skipped. Past and present windows apply.
    /// A skipped future phrase does not end the scan: a later past phrase in
    /// the same query ("tomorrow's agenda from last week") still applies.
    static func pastIngestTimeRange(inferredFrom query: String, anchorMs: Int64?) -> SearchTimeRange? {
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
                guard range.afterMs < anchorMs else { continue }
                return SearchTimeRange(after: range.afterMs, before: range.beforeMs)
            }
        }
        return nil
    }

    private func executeRecall(
        query: String,
        frameFilter: FrameFilter?,
        timeRange: SearchTimeRange?,
        topK: Int?,
        requestedMode: SearchMode?,
        scopeContext: MemoryScopeContext? = nil,
        maxContextTokens: Int? = nil,
        inferTimeRange: Bool = true
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
                diagnostics: .text(requested: resolvedRequestedMode, embedding: .notRequested)
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
            searchMode: effectiveSearchMode,
            scopeContext: scopeContext,
            maxContextTokens: maxContextTokens,
            inferTimeRange: inferTimeRange
        )

        var diagnostics = Self.retrievalDiagnostics(
            requested: resolvedRequestedMode,
            effective: context.diagnostics?.effectiveMode ?? effectiveSearchMode,
            embedding: queryEmbedding.state
        )
        diagnostics.inferredTimeRange = context.diagnostics?.inferredTimeRange
        return RecallExecution(context: context, diagnostics: diagnostics)
    }

    private struct QueryEmbeddingResult {
        let embedding: [Float]?
        let state: RAGContext.QueryEmbeddingState
    }

    private static func retrievalDiagnostics(
        requested: SearchMode,
        effective: SearchMode,
        embedding: RAGContext.QueryEmbeddingState
    ) -> RAGContext.Diagnostics {
        switch effective {
        case .textOnly:
            return .text(requested: requested, embedding: embedding)
        case .vectorOnly, .hybrid:
            if embedding == .available {
                return .vector(requested: requested, effective: effective)
            }
            return .text(requested: requested, embedding: embedding)
        }
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

    private func queryEmbedding(for query: String, policy: QueryEmbeddingPolicy) async throws -> [Float]? {
        return try await queryEmbeddingResult(
            for: query,
            policy: policy,
            attached: readyEmbedderSnapshot
        ).embedding
    }

    private func queryEmbeddingResult(
        for query: String,
        policy: QueryEmbeddingPolicy,
        attached: (any EmbeddingProvider)?
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
            guard supersededVectorsReason == nil else {
                scheduleAutomaticEmbeddingBackfillIfReady()
                return QueryEmbeddingResult(embedding: nil, state: .vectorsRebuilding)
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
            if let reason = supersededVectorsReason {
                scheduleAutomaticEmbeddingBackfillIfReady()
                throw WaxError.vectorsRebuilding(reason: reason, progress: supersededReembedProgress)
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
}
