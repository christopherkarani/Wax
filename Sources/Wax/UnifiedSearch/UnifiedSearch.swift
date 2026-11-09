import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

/// Fused (or single-lane) hit before metadata filtering and preview loading.
struct UnifiedSearchBaseResult {
    let frameId: UInt64
    let score: Float
    let sources: [SearchResponse.Source]
    let rankingDiagnostics: SearchResponse.RankingDiagnostics?
}

package struct UnifiedSearchEngineOverrides {
    var textEngine: FTS5SearchEngine? = nil
    /// Test injection. Production search uses `loadedVectorEngine` or the cache enum.
    var vectorEngine: (any VectorSearchEngine)? = nil
    var loadedVectorEngine: LoadedVectorSearchEngine? = nil
    var structuredEngine: FTS5SearchEngine? = nil
}

package extension Wax {
    func search(_ request: SearchRequest) async throws -> SearchResponse {
        try await search(request, engineOverrides: nil)
    }
}

extension Wax {
    func search(
        _ request: SearchRequest,
        engineOverrides: UnifiedSearchEngineOverrides?
    ) async throws -> SearchResponse {
        let requestedTopK = max(0, request.topK)
        if requestedTopK == 0 {
            return SearchResponse(results: [])
        }

        // Ranking/explanation passes share request.nowMs so semantic adjustments
        // agree within one search. asOfMs is a structured-fact cutoff, not ranking-now.
        let semanticNowMs = request.nowMs

        let plan = SearchPlan.make(request)
        let trimmedQuery = plan.trimmedQuery
        let queryType = plan.queryType
        let weights = plan.weights
        let includeText = plan.includeText
        let includeVector = plan.includeVector
        let exactIntentWindow = plan.exactIntentWindow
        let candidateLimit = plan.candidateLimit
        let filter = request.frameFilter ?? FrameFilter()

        let cache = UnifiedSearchEngineCache.shared
        let textEngine: FTS5SearchEngine? = if includeText {
            if let override = engineOverrides?.textEngine {
                override
            } else {
                try await cache.textEngine(for: self)
            }
        } else {
            nil
        }

        enum ResolvedVectorEngine {
            case loaded(LoadedVectorSearchEngine)
            case override(any VectorSearchEngine)

            func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
                switch self {
                case .loaded(let engine):
                    return try await engine.search(vector: vector, topK: topK)
                case .override(let engine):
                    return try await engine.search(vector: vector, topK: topK)
                }
            }
        }

        let resolvedVectorEngine: ResolvedVectorEngine? = if includeVector, let embedding = request.lane.embedding, !embedding.isEmpty {
            if let override = engineOverrides?.vectorEngine {
                .override(override)
            } else if let loaded = engineOverrides?.loadedVectorEngine {
                .loaded(loaded)
            } else if let loaded = try await cache.vectorEngine(
                for: self,
                queryEmbeddingDimensions: embedding.count,
                preference: request.vectorEnginePreference
            ) {
                .loaded(loaded)
            } else {
                nil
            }
        } else {
            nil
        }

        let structuredEngine: FTS5SearchEngine?
        if let trimmedQuery, !trimmedQuery.isEmpty {
            if let override = engineOverrides?.structuredEngine {
                structuredEngine = override
            } else if let textEngine {
                structuredEngine = textEngine
            } else {
                structuredEngine = try await cache.textEngine(for: self)
            }
        } else {
            structuredEngine = nil
        }


        async let textLaneAsync: (results: [TextSearchResult], isORFallbackOnly: Bool) = {
            guard includeText, let textEngine, let trimmedQuery, !trimmedQuery.isEmpty else {
                return ([], false)
            }
            // Empty MATCH plans (stopwords / operators only) must not fall back to
            // the raw user string — FTS5 would interpret AND/OR/NOT/NEAR as syntax.
            guard let matchPlan = plan.matchPlan else {
                return ([], false)
            }
            let primaryQuery = matchPlan.primaryMatch
            let fallbackQuery = matchPlan.fallbackMatch
            let queryTokenCount = matchPlan.tokenCount

            func merged(
                base: [TextSearchResult],
                fallback: [TextSearchResult],
                limit: Int
            ) -> [TextSearchResult] {
                guard !base.isEmpty else {
                    return Self.scoredAsORFallbackOnly(
                        Array(fallback.prefix(limit)),
                        tokenCount: queryTokenCount
                    )
                }
                if base.count >= limit { return Array(base.prefix(limit)) }

                var seen = Set(base.map(\.frameId))
                var combined = base
                combined.reserveCapacity(limit)
                for candidate in fallback {
                    guard !seen.contains(candidate.frameId) else { continue }
                    combined.append(
                        Self.scoredAsORFallbackOnly(candidate, tokenCount: queryTokenCount)
                    )
                    seen.insert(candidate.frameId)
                    if combined.count >= limit { break }
                }
                return combined
            }

            do {
                let base = try await textEngine.search(matchQuery: primaryQuery, topK: candidateLimit)
                guard let fallbackQuery else {
                    return (Array(base.prefix(candidateLimit)), false)
                }
                let fallback = try await textEngine.search(matchQuery: fallbackQuery, topK: candidateLimit)
                if base.isEmpty {
                    return (
                        Self.scoredAsORFallbackOnly(
                            Array(fallback.prefix(candidateLimit)),
                            tokenCount: queryTokenCount
                        ),
                        true
                    )
                }
                return (merged(base: base, fallback: fallback, limit: candidateLimit), false)
            } catch {
                guard let fallbackQuery else {
                    throw error
                }
                let fallback = try await textEngine.search(matchQuery: fallbackQuery, topK: candidateLimit)
                return (Self.scoredAsORFallbackOnly(fallback, tokenCount: queryTokenCount), true)
            }
        }()

        async let vectorLaneAsync: (results: [(frameId: UInt64, score: Float)], timedOut: Bool) = {
            guard includeVector, let resolvedVectorEngine, let embedding = request.lane.embedding, !embedding.isEmpty else {
                return ([], false)
            }
            if let timeout = request.vectorSearchTimeout {
                do {
                    let results = try await AsyncTimeout.run(timeout: timeout, operation: "vector search") {
                        try await resolvedVectorEngine.search(vector: embedding, topK: candidateLimit)
                    }
                    return (results, false)
                } catch let error as AsyncTimeout.TimeoutError {
                    // Hybrid/text modes can degrade to non-vector lanes; vectorOnly should fail hard.
                    if case .vectorOnly = request.lane {
                        throw error
                    }
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "unified search vector lane timeout",
                        fallback: "fall back to non-vector lanes"
                    )
                    return ([], true)
                }
            } else {
                return (try await resolvedVectorEngine.search(vector: embedding, topK: candidateLimit), false)
            }
        }()

        async let structuredFrameIdsAsync: [UInt64] = {
            guard let trimmedQuery, !trimmedQuery.isEmpty else { return [] }
            let options = request.structuredMemory
            guard options.weight > 0,
                  options.maxEntityCandidates > 0,
                  options.maxFacts > 0,
                  options.maxEvidenceFrames > 0,
                  let structuredEngine
            else { return [] }

            // Without any entity alias no candidate can resolve; skip the per-token queries.
            guard try await structuredEngine.hasEntityAliases() else { return [] }
            let candidates = try await Self.structuredEntityCandidates(
                query: trimmedQuery,
                engine: structuredEngine,
                maxCandidates: options.maxEntityCandidates
            )
            guard !candidates.isEmpty else { return [] }

            let asOf = StructuredMemoryAsOf(asOfMs: request.asOfMs)
            return try await structuredEngine.evidenceFrameIds(
                subjectKeys: candidates,
                asOf: asOf,
                maxFacts: options.maxFacts,
                maxFrames: options.maxEvidenceFrames,
                requireEvidenceSpan: options.requireEvidenceSpan
            )
        }()

        let textLane = try await textLaneAsync
        let textResults = textLane.results
        let textLaneIsORFallbackOnly = textLane.isORFallbackOnly
        let vectorLane = try await vectorLaneAsync
        var vectorResults = vectorLane.results
        let vectorSearchTimedOut = vectorLane.timedOut
        vectorResults.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameId < rhs.frameId
        }
        let structuredFrameIds = try await structuredFrameIdsAsync

        // Only hybrid fusion reads the recency lane, and the timeline walks every frame, so
        // single-lane searches skip it.
        var timelineFrameIds: [UInt64] = []
        if case .hybrid = request.lane, queryType == .temporal, weights.temporal > 0 {
            let timelineQuery = TimelineQuery(
                limit: max(candidateLimit, request.timelineFallbackLimit),
                order: .reverseChronological,
                after: request.timeRange?.after,
                before: request.timeRange?.before,
                includeDeleted: filter.includeDeleted,
                includeSuperseded: filter.includeSuperseded
            )
            timelineFrameIds = await timeline(timelineQuery)
                .filter { filter.includeSurrogates || FrameKind(rawKind: $0.kind) != .surrogate }
                .map(\.id)
        }

        let snippetByFrameId: [UInt64: String] = textResults.reduce(into: [:]) { acc, result in
            guard let snippet = result.snippet, !snippet.isEmpty else { return }
            acc[result.frameId] = snippet
        }

        let structuredIds = structuredFrameIds
        let structuredWeight = max(0, request.structuredMemory.weight)
        let diagnosticsEnabled = request.enableRankingDiagnostics
        let diagnosticsTopK = max(1, request.rankingDiagnosticsTopK)

        var baseResults: [UnifiedSearchBaseResult]
        switch request.lane {
        case .textOnly:
            if structuredIds.isEmpty || structuredWeight <= 0 {
                baseResults = Self.singleLaneBaseResults(
                    textResults.map { (frameId: $0.frameId, score: Float($0.score)) },
                    source: .text,
                    weight: 1,
                    diagnosticsEnabled: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )
            } else {
                let (textIds, textSet) = Self.frameIDsAndSet(from: textResults.lazy.map(\.frameId))
                let fused = HybridSearch.rrfFusionResults(
                    lists: [
                        (source: .text, weight: weights.bm25, frameIds: textIds),
                        (source: .structured, weight: structuredWeight, frameIds: structuredIds),
                    ],
                    k: request.rrfK,
                    includeDiagnostics: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )

                baseResults = fused.map { entry in
                    let sources = entry.sources.isEmpty
                        ? (textSet.contains(entry.frameId) ? [.text] : [.structured])
                        : entry.sources
                    return UnifiedSearchBaseResult(
                        frameId: entry.frameId,
                        score: entry.score,
                        sources: sources,
                        rankingDiagnostics: entry.diagnostics
                    )
                }
            }
        case .vectorOnly:
            if structuredIds.isEmpty || structuredWeight <= 0 {
                baseResults = Self.singleLaneBaseResults(
                    vectorResults,
                    source: .vector,
                    weight: 1,
                    diagnosticsEnabled: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )
            } else {
                let (vectorIds, vectorSet) = Self.frameIDsAndSet(from: vectorResults.lazy.map(\.frameId))
                let fused = HybridSearch.rrfFusionResults(
                    lists: [
                        (source: .vector, weight: weights.vector, frameIds: vectorIds),
                        (source: .structured, weight: structuredWeight, frameIds: structuredIds),
                    ],
                    k: request.rrfK,
                    includeDiagnostics: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )

                baseResults = fused.map { entry in
                    let sources = entry.sources.isEmpty
                        ? (vectorSet.contains(entry.frameId) ? [.vector] : [.structured])
                        : entry.sources
                    return UnifiedSearchBaseResult(
                        frameId: entry.frameId,
                        score: entry.score,
                        sources: sources,
                        rankingDiagnostics: entry.diagnostics
                    )
                }
            }
        case .hybrid(let alpha, _):
            let clampedAlpha = min(1, max(0, alpha))
            let textWeight = weights.bm25 * clampedAlpha
            let vectorWeight = weights.vector * (1 - clampedAlpha)

            let (textIds, textSet) = Self.frameIDsAndSet(from: textResults.lazy.map(\.frameId))
            let (vectorIds, vectorSet) = Self.frameIDsAndSet(from: vectorResults.lazy.map(\.frameId))
            // Recency only reorders frames that matched the query. Ranking every
            // recent frame pushes unrelated notes above the relevant ones.
            let timelineIds = timelineFrameIds.filter { textSet.contains($0) || vectorSet.contains($0) }

            var lists: [(source: SearchResponse.Source, weight: Float, frameIds: [UInt64])] = []
            if textWeight > 0, !textIds.isEmpty { lists.append((source: .text, weight: textWeight, frameIds: textIds)) }
            if vectorWeight > 0, !vectorIds.isEmpty { lists.append((source: .vector, weight: vectorWeight, frameIds: vectorIds)) }
            if weights.temporal > 0, !timelineIds.isEmpty { lists.append((source: .timeline, weight: weights.temporal, frameIds: timelineIds)) }
            if structuredWeight > 0, !structuredIds.isEmpty { lists.append((source: .structured, weight: structuredWeight, frameIds: structuredIds)) }

            if lists.count == 1, lists[0].source == .vector {
                // Hybrid with only the vector lane must keep engine similarity.
                // Rank-only RRF collapses 0.95 and 0.20 to the same published 1.0.
                baseResults = Self.singleLaneBaseResults(
                    vectorResults,
                    source: .vector,
                    weight: vectorWeight,
                    diagnosticsEnabled: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )
                break
            }

            var fused = HybridSearch.rrfFusionResults(
                lists: lists,
                k: request.rrfK,
                includeDiagnostics: diagnosticsEnabled,
                diagnosticsTopK: diagnosticsTopK
            )

            // Factual identifier path only: exclusive FTS rank-1 must not lose
            // to an exclusive vector neighbor. Skip OR-fallback-only rank-1 even
            // on factual. Semantic/exploratory keep AdaptiveFusion.
            var fusedPairs = fused.map { ($0.frameId, $0.score) }
            HybridSearch.applyExclusiveTextRank1Floor(
                merged: &fusedPairs,
                textFrameIds: textIds,
                vectorFrameIds: vectorIds,
                applyFloor: queryType == .factual,
                textRank1IsORFallbackOnly: textLaneIsORFallbackOnly
            )
            let totalWeight = lists.reduce(Float(0)) { $0 + max(0, $1.weight) }
            HybridSearch.publishNormalizedRRFScores(
                &fusedPairs,
                k: request.rrfK,
                totalWeight: totalWeight
            )
            let fusedById = Dictionary(uniqueKeysWithValues: fused.map { ($0.frameId, $0) })
            fused = fusedPairs.compactMap { pair in
                guard var entry = fusedById[pair.0] else { return nil }
                entry.score = pair.1
                return entry
            }

            let timelineSet = Set(timelineIds)
            let structuredSet = Set(structuredIds)

            baseResults = fused.map { entry in
                var sources = entry.sources
                if sources.isEmpty {
                    if textSet.contains(entry.frameId) { sources.append(.text) }
                    if vectorSet.contains(entry.frameId) { sources.append(.vector) }
                    if timelineSet.contains(entry.frameId) { sources.append(.timeline) }
                    if structuredSet.contains(entry.frameId) { sources.append(.structured) }
                }
                return UnifiedSearchBaseResult(
                    frameId: entry.frameId,
                    score: entry.score,
                    sources: sources,
                    rankingDiagnostics: entry.diagnostics
                )
            }
        }

        // For a lexical/vector query, `filters.frame_ids` is an allowlist of
        // frames to consider, not only a post-filter on FTS hits. Deleted rows
        // drop out of the text index after a durable reopen; still surface
        // those IDs so include_deleted / include_superseded can return them.
        // Constraint-only queries (no text) already rank via timeline — do not
        // reinsert the allowlist in ID order and scramble that ranking.
        let hasLexicalOrVectorQuery = (request.query?.isEmpty == false) || request.lane.hasNonEmptyEmbedding
        if hasLexicalOrVectorQuery, let allowlist = filter.frameIds, !allowlist.isEmpty {
            let seen = Set(baseResults.map(\.frameId))
            for frameId in allowlist.sorted() where !seen.contains(frameId) {
                baseResults.append(
                    UnifiedSearchBaseResult(
                        frameId: frameId,
                        score: 0,
                        sources: [],
                        rankingDiagnostics: nil
                    )
                )
            }
        }

        struct PendingResult {
            let frameId: UInt64
            let score: Float
            let sources: [SearchResponse.Source]
            let snippet: String?
            let rankingDiagnostics: SearchResponse.RankingDiagnostics?
            let metadata: [String: String]
        }

        var pendingResults: [PendingResult] = []
        let pendingLimit = exactIntentWindow ?? requestedTopK
        pendingResults.reserveCapacity(min(pendingLimit, baseResults.count))

        if !baseResults.isEmpty {
            // Optimization: Use lazy metadata loading for small result sets
            // Dictionary-building overhead dominates for small scales (<50 items)
            // Prefetch is only beneficial for larger result sets
            let lazyMetadataThreshold = max(1, request.metadataLoadingThreshold)
            
            if baseResults.count >= lazyMetadataThreshold {
                // Batch prefetch for large result sets
                let metaById = await frameMetasIncludingPending(frameIds: baseResults.map(\.frameId))
                
                for item in baseResults {
                    guard let meta = metaById[item.frameId] else { continue }
                    guard Self.passesFrameFilter(
                        meta: meta,
                        frameId: item.frameId,
                        score: item.score,
                        request: request,
                        filter: filter
                    ) else { continue }
                    // Expired memories are dropped by semantic rerank; skip them
                    // here so they do not consume topK slots.
                    guard !Self.isExpiredMemory(meta: meta, nowMs: semanticNowMs) else { continue }

                    pendingResults.append(
                        PendingResult(
                            frameId: item.frameId,
                            score: item.score,
                            sources: item.sources,
                            snippet: snippetByFrameId[item.frameId],
                            rankingDiagnostics: item.rankingDiagnostics,
                            metadata: meta.metadata?.entries ?? [:]
                        )
                    )

                    if pendingResults.count >= pendingLimit {
                        break
                    }
                }
            } else {
                // Lazy loading for small result sets - avoids dictionary overhead
                for item in baseResults {
                    let meta: FrameMeta
                    do {
                        meta = try await frameMetaIncludingPending(frameId: item.frameId)
                    } catch {
                        WaxDiagnostics.logSwallowed(
                            error,
                            context: "unified search frame metadata lookup",
                            fallback: "skip result without metadata"
                        )
                        continue
                    }
                    guard Self.passesFrameFilter(
                        meta: meta,
                        frameId: item.frameId,
                        score: item.score,
                        request: request,
                        filter: filter
                    ) else { continue }
                    // Expired memories are dropped by semantic rerank; skip them
                    // here so they do not consume topK slots.
                    guard !Self.isExpiredMemory(meta: meta, nowMs: semanticNowMs) else { continue }

                    pendingResults.append(
                        PendingResult(
                            frameId: item.frameId,
                            score: item.score,
                            sources: item.sources,
                            snippet: snippetByFrameId[item.frameId],
                            rankingDiagnostics: item.rankingDiagnostics,
                            metadata: meta.metadata?.entries ?? [:]
                        )
                    )

                    if pendingResults.count >= pendingLimit {
                        break
                    }
                }
            }
        }

        let previewIds = pendingResults
            .filter { $0.snippet == nil }
            .map(\.frameId)
        let previewById = try await framePreviews(
            frameIds: previewIds,
            maxBytes: request.previewMaxBytes
        )

        var filtered: [SearchResponse.Result] = pendingResults.enumerated().map { index, item in
            let previewText: String?
            if let snippet = item.snippet {
                previewText = snippet
            } else {
                previewText = previewById[item.frameId]
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            let rankingDiagnostics: SearchResponse.RankingDiagnostics? =
                if diagnosticsEnabled, index < diagnosticsTopK {
                    item.rankingDiagnostics
                } else {
                    nil
                }
            return SearchResponse.Result(
                frameId: item.frameId,
                score: item.score,
                previewText: previewText,
                sources: item.sources,
                rankingDiagnostics: rankingDiagnostics,
                metadata: item.metadata,
                explanations: Self.baseExplanations(
                    sources: item.sources,
                    rankingDiagnostics: rankingDiagnostics,
                    metadata: item.metadata,
                    scopeContext: request.scopeContext,
                    nowMs: semanticNowMs
                )
            )
        }

        if let trimmedQuery, !trimmedQuery.isEmpty {
            filtered = UnifiedRanking.intentAwareRerank(
                results: filtered,
                query: trimmedQuery,
                maxWindow: min(max(SearchPlan.boundedMultiply(request.topK, by: 2), 10), 32)
            )
        }
        filtered = UnifiedRanking.semanticMemoryRerank(
            results: filtered,
            scopeContext: request.scopeContext,
            nowMs: semanticNowMs,
            maxWindow: min(max(SearchPlan.boundedMultiply(request.topK, by: 3), 12), 48)
        )
        if let trimmedQuery, !trimmedQuery.isEmpty {
            filtered = UnifiedRanking.distinctiveTokenRerank(
                results: filtered,
                query: trimmedQuery,
                nowMs: semanticNowMs,
                maxWindow: min(max(SearchPlan.boundedMultiply(request.topK, by: 3), 12), 48)
            )
        }
        if let exactIntentWindow, let trimmedQuery {
            filtered = UnifiedRanking.identifierExactMatchRerank(
                results: filtered,
                query: trimmedQuery,
                maxWindow: exactIntentWindow
            )
        }
        if filtered.count > requestedTopK {
            filtered = Array(filtered.prefix(requestedTopK))
        }

        if filtered.isEmpty, request.allowTimelineFallback {
            filtered = await timelineFallbackResults(request: request, filter: filter, nowMs: semanticNowMs)
        }

        return SearchResponse(results: filtered, vectorSearchTimedOut: vectorSearchTimedOut)
    }
}
