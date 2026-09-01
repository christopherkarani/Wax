import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

struct UnifiedSearchEngineOverrides {
    var textEngine: FTS5SearchEngine?
    var vectorEngine: (any VectorSearchEngine)?
    var structuredEngine: FTS5SearchEngine?
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

        let trimmedQuery = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let queryType: QueryType
        if let trimmedQuery, !trimmedQuery.isEmpty {
            queryType = RuleBasedQueryClassifier.classify(trimmedQuery)
        } else {
            queryType = .exploratory
        }

        let weights = AdaptiveFusionConfig.default.weights(for: queryType)
        let filter = request.frameFilter ?? FrameFilter()

        let includeText: Bool
        let includeVector: Bool
        switch request.mode {
        case .textOnly:
            includeText = true
            includeVector = false
        case .vectorOnly:
            let hasEmbedding = !(request.embedding?.isEmpty ?? true)
            guard hasEmbedding else {
                throw WaxError.io("vectorOnly search requires a non-empty query embedding")
            }
            includeText = false
            includeVector = true
        case .hybrid:
            includeText = true
            includeVector = true
        }

        // Exact-intent overfetch + rerank are text-lane only. vectorOnly must not
        // widen the pending window or promote a buried lexical frame.
        let exactIntentWindow: Int? = (
            includeText && (trimmedQuery.map(RuleBasedQueryClassifier.isExactIntentQuery) ?? false)
        ) ? min(max(Self.boundedMultiply(requestedTopK, by: 3), 12), 48) : nil

        let candidateLimit = Self.candidateLimit(for: requestedTopK, filter: filter)
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

        let vectorEngine: (any VectorSearchEngine)? = if includeVector, let embedding = request.embedding, !embedding.isEmpty {
            if let override = engineOverrides?.vectorEngine {
                override
            } else {
                try await cache.vectorEngine(
                    for: self,
                    queryEmbeddingDimensions: embedding.count,
                    preference: request.vectorEnginePreference
                )
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
            guard let plan = MatchPlan.plan(query: trimmedQuery) else {
                return ([], false)
            }
            let primaryQuery = plan.primaryMatch
            let fallbackQuery = plan.fallbackMatch
            let queryTokenCount = plan.tokenCount

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

        async let vectorResultsAsync: [(frameId: UInt64, score: Float)] = {
            guard includeVector, let vectorEngine, let embedding = request.embedding, !embedding.isEmpty else { return [] }
            var queryEmbedding = embedding
            #if canImport(Metal)
            let isMetalEngine = vectorEngine is MetalVectorEngine
            if isMetalEngine, !VectorMath.isNormalizedL2(queryEmbedding) {
                queryEmbedding = VectorMath.normalizeL2(queryEmbedding)
            }
            #endif
            let vectorToSearch = queryEmbedding
            if let timeout = request.vectorSearchTimeout {
                do {
                    return try await AsyncTimeout.run(timeout: timeout, operation: "vector search") {
                        try await vectorEngine.search(vector: vectorToSearch, topK: candidateLimit)
                    }
                } catch let error as AsyncTimeout.TimeoutError {
                    // Hybrid/text modes can degrade to non-vector lanes; vectorOnly should fail hard.
                    if request.mode == .vectorOnly {
                        throw error
                    }
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "unified search vector lane timeout",
                        fallback: "fall back to non-vector lanes"
                    )
                    return []
                }
            } else {
                return try await vectorEngine.search(vector: vectorToSearch, topK: candidateLimit)
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
        var vectorResults = try await vectorResultsAsync
        vectorResults.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameId < rhs.frameId
        }
        let structuredFrameIds = try await structuredFrameIdsAsync

        var timelineFrameIds: [UInt64] = []
        if queryType == .temporal, weights.temporal > 0 {
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

        struct BaseResult {
            let frameId: UInt64
            let score: Float
            let sources: [SearchResponse.Source]
            let rankingDiagnostics: SearchResponse.RankingDiagnostics?
        }

        var baseResults: [BaseResult]
        switch request.mode {
        case .textOnly:
            if structuredIds.isEmpty || structuredWeight <= 0 {
                baseResults = textResults.enumerated().map { index, result in
                    let diagnostics: SearchResponse.RankingDiagnostics?
                    if diagnosticsEnabled, index < diagnosticsTopK {
                        diagnostics = .init(
                            bestLaneRank: index + 1,
                            laneContributions: [
                                .init(
                                    source: .text,
                                    weight: 1,
                                    rank: index + 1,
                                    rrfScore: Float(result.score)
                                ),
                            ],
                            tieBreakReason: index == 0 ? .topResult : .fusedScore
                        )
                    } else {
                        diagnostics = nil
                    }
                    return BaseResult(
                        frameId: result.frameId,
                        score: Float(result.score),
                        sources: [.text],
                        rankingDiagnostics: diagnostics
                    )
                }
            } else {
                let (textIds, textSet) = Self.frameIDsAndSet(from: textResults.lazy.map(\.frameId))
                let fused = Self.rrfFusionResults(
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
                    return BaseResult(
                        frameId: entry.frameId,
                        score: entry.score,
                        sources: sources,
                        rankingDiagnostics: entry.diagnostics
                    )
                }
            }
        case .vectorOnly:
            if structuredIds.isEmpty || structuredWeight <= 0 {
                baseResults = vectorResults.enumerated().map { index, result in
                    let diagnostics: SearchResponse.RankingDiagnostics?
                    if diagnosticsEnabled, index < diagnosticsTopK {
                        diagnostics = .init(
                            bestLaneRank: index + 1,
                            laneContributions: [
                                .init(
                                    source: .vector,
                                    weight: 1,
                                    rank: index + 1,
                                    rrfScore: result.score
                                ),
                            ],
                            tieBreakReason: index == 0 ? .topResult : .fusedScore
                        )
                    } else {
                        diagnostics = nil
                    }
                    return BaseResult(
                        frameId: result.frameId,
                        score: result.score,
                        sources: [.vector],
                        rankingDiagnostics: diagnostics
                    )
                }
            } else {
                let (vectorIds, vectorSet) = Self.frameIDsAndSet(from: vectorResults.lazy.map(\.frameId))
                let fused = Self.rrfFusionResults(
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
                    return BaseResult(
                        frameId: entry.frameId,
                        score: entry.score,
                        sources: sources,
                        rankingDiagnostics: entry.diagnostics
                    )
                }
            }
        case .hybrid(let alpha):
            let clampedAlpha = min(1, max(0, alpha))
            let textWeight = weights.bm25 * clampedAlpha
            let vectorWeight = weights.vector * (1 - clampedAlpha)

            let (textIds, textSet) = Self.frameIDsAndSet(from: textResults.lazy.map(\.frameId))
            let (vectorIds, vectorSet) = Self.frameIDsAndSet(from: vectorResults.lazy.map(\.frameId))
            let timelineIds = timelineFrameIds

            var lists: [(source: SearchResponse.Source, weight: Float, frameIds: [UInt64])] = []
            if textWeight > 0, !textIds.isEmpty { lists.append((source: .text, weight: textWeight, frameIds: textIds)) }
            if vectorWeight > 0, !vectorIds.isEmpty { lists.append((source: .vector, weight: vectorWeight, frameIds: vectorIds)) }
            if weights.temporal > 0, !timelineIds.isEmpty { lists.append((source: .timeline, weight: weights.temporal, frameIds: timelineIds)) }
            if structuredWeight > 0, !structuredIds.isEmpty { lists.append((source: .structured, weight: structuredWeight, frameIds: structuredIds)) }

            var fused = Self.rrfFusionResults(
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
                return BaseResult(
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
        let hasLexicalOrVectorQuery = (request.query?.isEmpty == false) || request.embedding != nil
        if hasLexicalOrVectorQuery, let allowlist = filter.frameIds, !allowlist.isEmpty {
            let seen = Set(baseResults.map(\.frameId))
            for frameId in allowlist.sorted() where !seen.contains(frameId) {
                baseResults.append(
                    BaseResult(
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
                maxWindow: min(max(Self.boundedMultiply(request.topK, by: 2), 10), 32)
            )
        }
        filtered = UnifiedRanking.semanticMemoryRerank(
            results: filtered,
            scopeContext: request.scopeContext,
            nowMs: semanticNowMs,
            maxWindow: min(max(Self.boundedMultiply(request.topK, by: 3), 12), 48)
        )
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

        return SearchResponse(results: filtered)
    }

    private func timelineFallbackResults(request: SearchRequest, filter: FrameFilter, nowMs: Int64) async -> [SearchResponse.Result] {
        if request.timelineFallbackLimit <= 0 { return [] }
        let query = TimelineQuery(
            limit: request.timelineFallbackLimit,
            order: .reverseChronological,
            after: request.timeRange?.after,
            before: request.timeRange?.before,
            includeDeleted: filter.includeDeleted,
            includeSuperseded: filter.includeSuperseded
        )

        var results: [SearchResponse.Result] = []
        results.reserveCapacity(max(0, request.timelineFallbackLimit))

        let frames = await timeline(query)
        let previewById: [UInt64: Data]
        do {
            previewById = try await framePreviews(
                frameIds: frames.map(\.id),
                maxBytes: request.previewMaxBytes
            )
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "unified search timeline fallback previews",
                fallback: "empty preview map"
            )
            previewById = [:]
        }

        for (rank, meta) in frames.enumerated() {
            let frameId = meta.id
            let score = 1 / Float(max(0, request.rrfK) + rank + 1)
            guard Self.passesFrameFilter(
                meta: meta,
                frameId: frameId,
                score: score,
                request: request,
                filter: filter
            ) else { continue }
            let previewText = previewById[frameId]
                .flatMap { String(data: $0, encoding: .utf8) }

            results.append(
                SearchResponse.Result(
                    frameId: frameId,
                    score: score,
                    previewText: previewText,
                    sources: [.timeline],
                    metadata: meta.metadata?.entries ?? [:],
                    explanations: Self.baseExplanations(
                        sources: [.timeline],
                        rankingDiagnostics: nil,
                        metadata: meta.metadata?.entries ?? [:],
                        scopeContext: request.scopeContext,
                        nowMs: nowMs
                    )
                )
            )

            if results.count >= request.timelineFallbackLimit {
                break
            }
        }

        return results
    }

    private static func baseExplanations(
        sources: [SearchResponse.Source],
        rankingDiagnostics: SearchResponse.RankingDiagnostics?,
        metadata: [String: String],
        scopeContext: MemoryScopeContext?,
        nowMs: Int64
    ) -> [String] {
        var reasons: [String] = []
        if sources.contains(.vector) {
            reasons.append("semantic match")
        }
        if sources.contains(.text) {
            reasons.append("keyword match")
        }
        if sources.contains(.structured) {
            reasons.append("linked entity or fact evidence")
        }
        if sources.contains(.timeline) {
            reasons.append("timeline fallback")
        }
        if let rankingDiagnostics {
            if let bestLane = rankingDiagnostics.bestLaneRank, bestLane == 1 {
                reasons.append("top lane result")
            }
            if rankingDiagnostics.tieBreakReason == SearchResponse.RankingTieBreakReason.rerankComposite {
                reasons.append("intent-aware rerank")
            }
        }
        let semantic = MemorySemantics.rankingReasons(
            metadata: metadata,
            scope: scopeContext,
            nowMs: nowMs
        )
        reasons.append(contentsOf: semantic.reasons)
        return UnifiedRanking.dedupedExplanations(reasons)
    }

    /// OR-fallback-only hits cannot publish a saturated 1.0 for a 1-of-N overlap.
    private static func orFallbackOnlyScoreScale(tokenCount: Int) -> Double {
        let n = max(tokenCount, 1)
        guard n > 1 else { return 1 }
        return 1 / Double(n)
    }

    private static func scoredAsORFallbackOnly(
        _ result: TextSearchResult,
        tokenCount: Int
    ) -> TextSearchResult {
        let scale = orFallbackOnlyScoreScale(tokenCount: tokenCount)
        guard scale < 1 else { return result }
        return TextSearchResult(
            frameId: result.frameId,
            score: result.score * scale,
            snippet: result.snippet
        )
    }

    private static func scoredAsORFallbackOnly(
        _ results: [TextSearchResult],
        tokenCount: Int
    ) -> [TextSearchResult] {
        let scale = orFallbackOnlyScoreScale(tokenCount: tokenCount)
        guard scale < 1 else { return results }
        return results.map { scoredAsORFallbackOnly($0, tokenCount: tokenCount) }
    }

    private struct RRFFusedCandidate {
        let frameId: UInt64
        let score: Float
        let bestRank: Int
        let sources: [SearchResponse.Source]
        let laneContributions: [SearchResponse.RankingLaneContribution]
    }

    private static func rrfFusionResults(
        lists: [(source: SearchResponse.Source, weight: Float, frameIds: [UInt64])],
        k: Int,
        includeDiagnostics: Bool,
        diagnosticsTopK: Int
    ) -> [(frameId: UInt64, score: Float, sources: [SearchResponse.Source], diagnostics: SearchResponse.RankingDiagnostics?)] {
        let kConstant = max(0, k)
        struct Accumulator {
            var score: Float = 0
            var bestRank: Int = .max
            var sources: [SearchResponse.Source] = []
            var laneContributions: [SearchResponse.RankingLaneContribution] = []
        }
        let estimatedFrameCount = lists.reduce(into: 0) { partial, list in
            partial += list.frameIds.count
        }
        var byFrame: [UInt64: Accumulator] = [:]
        byFrame.reserveCapacity(estimatedFrameCount)

        for list in lists {
            guard list.weight > 0 else { continue }
            for (rankZeroBased, frameId) in list.frameIds.enumerated() {
                let rank = rankZeroBased + 1
                let contribution = list.weight / Float(kConstant + rank)
                var acc = byFrame[frameId] ?? Accumulator()
                acc.score += contribution
                acc.bestRank = min(acc.bestRank, rank)
                if !acc.sources.contains(list.source) {
                    acc.sources.append(list.source)
                }
                if includeDiagnostics {
                    acc.laneContributions.append(
                        .init(
                            source: list.source,
                            weight: list.weight,
                            rank: rank,
                            rrfScore: contribution
                        )
                    )
                }
                byFrame[frameId] = acc
            }
        }

        var ranked: [RRFFusedCandidate] = []
        ranked.reserveCapacity(byFrame.count)
        for (frameId, acc) in byFrame {
            let contributions = includeDiagnostics
                ? acc.laneContributions.sorted { lhs, rhs in
                    if lhs.rrfScore != rhs.rrfScore { return lhs.rrfScore > rhs.rrfScore }
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                : []
            ranked.append(
                RRFFusedCandidate(
                    frameId: frameId,
                    score: acc.score,
                    bestRank: acc.bestRank,
                    sources: acc.sources.sorted { $0.rawValue < $1.rawValue },
                    laneContributions: contributions
                )
            )
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.bestRank != rhs.bestRank { return lhs.bestRank < rhs.bestRank }
            return lhs.frameId < rhs.frameId
        }

        let topDiagLimit = max(1, diagnosticsTopK)
        var fused: [(frameId: UInt64, score: Float, sources: [SearchResponse.Source], diagnostics: SearchResponse.RankingDiagnostics?)] = []
        fused.reserveCapacity(ranked.count)
        for index in ranked.indices {
            let candidate = ranked[index]
            let diagnostics: SearchResponse.RankingDiagnostics?
            if includeDiagnostics, index < topDiagLimit {
                let reason: SearchResponse.RankingTieBreakReason
                if index == 0 {
                    reason = .topResult
                } else {
                    let previous = ranked[index - 1]
                    if previous.score != candidate.score {
                        reason = .fusedScore
                    } else if previous.bestRank != candidate.bestRank {
                        reason = .bestLaneRank
                    } else {
                        reason = .frameID
                    }
                }
                diagnostics = .init(
                    bestLaneRank: candidate.bestRank == .max ? nil : candidate.bestRank,
                    laneContributions: candidate.laneContributions,
                    tieBreakReason: reason
                )
            } else {
                diagnostics = nil
            }

            fused.append(
                (
                    frameId: candidate.frameId,
                    score: candidate.score,
                    sources: candidate.sources,
                    diagnostics: diagnostics
                )
            )
        }
        return fused
    }

    package static func dehighlightedPreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    private static func structuredEntityCandidates(
        query: String,
        engine: FTS5SearchEngine,
        maxCandidates: Int
    ) async throws -> [EntityKey] {
        let capped = max(0, min(maxCandidates, 10_000))
        guard capped > 0 else { return [] }

        var candidates: [String: (rank: Int, aliasLength: Int)] = [:]

        let fullAlias = StructuredMemoryCanonicalizer.normalizedAlias(query)
        if !fullAlias.isEmpty {
            let matches = try await engine.resolveEntities(matchingAlias: fullAlias, limit: capped)
            for match in matches {
                let key = match.key.rawValue
                let aliasLength = fullAlias.count
                if let existing = candidates[key] {
                    if 0 < existing.rank || (existing.rank == 0 && aliasLength > existing.aliasLength) {
                        candidates[key] = (rank: 0, aliasLength: aliasLength)
                    }
                } else {
                    candidates[key] = (rank: 0, aliasLength: aliasLength)
                }
            }
        }

        let tokens = MatchPlan.aliasTokens(from: query)
        var seenTokens: Set<String> = []
        for token in tokens {
            let normalized = StructuredMemoryCanonicalizer.normalizedAlias(token)
            if normalized.count < 2 { continue }
            if !seenTokens.insert(normalized).inserted { continue }

            let matches = try await engine.resolveEntities(matchingAlias: normalized, limit: capped)
            for match in matches {
                let key = match.key.rawValue
                let aliasLength = normalized.count
                if let existing = candidates[key] {
                    if 1 < existing.rank || (existing.rank == 1 && aliasLength > existing.aliasLength) {
                        candidates[key] = (rank: 1, aliasLength: aliasLength)
                    }
                } else {
                    candidates[key] = (rank: 1, aliasLength: aliasLength)
                }
            }
        }

        let sorted = candidates.map { (key, value) in
            (key: key, rank: value.rank, aliasLength: value.aliasLength)
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.aliasLength != rhs.aliasLength { return lhs.aliasLength > rhs.aliasLength }
            return lhs.key < rhs.key
        }

        return sorted.prefix(capped).map { EntityKey($0.key) }
    }

    private static func candidateLimit(for topK: Int) -> Int {
        guard topK > 0 else { return 0 }
        let expanded = boundedMultiply(topK, by: 3)
        let capped = min(expanded, 1000)
        // Keep the public request's topK from becoming an unbounded SQLite or
        // vector-engine limit. FTS independently caps at 10,000; matching the
        // same ceiling here also makes Int.max requests safe.
        return min(max(topK, capped), 10_000)
    }

    private static func candidateLimit(for topK: Int, filter: FrameFilter) -> Int {
        let baseLimit = candidateLimit(for: topK)
        guard needsCallerFilterOverfetch(filter) else { return baseLimit }

        let multiplied = boundedMultiply(topK, by: 5)
        let withSlack = topK > Int.max - 200 ? Int.max : topK + 200
        let overfetchLimit = min(1000, max(multiplied, withSlack))
        return max(baseLimit, overfetchLimit)
    }

    private static func boundedMultiply(_ value: Int, by multiplier: Int) -> Int {
        guard value > 0, multiplier > 0 else { return 0 }
        guard value <= Int.max / multiplier else { return Int.max }
        return value * multiplier
    }

    private static func needsCallerFilterOverfetch(_ filter: FrameFilter) -> Bool {
        if filter.frameIds != nil { return true }
        guard let metadataFilter = filter.metadataFilter else { return false }
        return !metadataFilter.requiredEntries.isEmpty
            || !metadataFilter.requiredTags.isEmpty
            || !metadataFilter.requiredLabels.isEmpty
    }

    private static func frameIDsAndSet<S: Sequence>(from frameIDs: S) -> ([UInt64], Set<UInt64>)
    where S.Element == UInt64 {
        var ids: [UInt64] = []
        var set: Set<UInt64> = []
        ids.reserveCapacity(frameIDs.underestimatedCount)
        set.reserveCapacity(frameIDs.underestimatedCount)
        for frameId in frameIDs {
            ids.append(frameId)
            set.insert(frameId)
        }
        return (ids, set)
    }

    private static func matches(metadataFilter: MetadataFilter, meta: FrameMeta) -> Bool {
        if !metadataFilter.requiredEntries.isEmpty {
            guard let entries = meta.metadata?.entries else { return false }
            for (key, value) in metadataFilter.requiredEntries {
                guard entries[key] == value else { return false }
            }
        }

        if !metadataFilter.requiredTags.isEmpty {
            for required in metadataFilter.requiredTags {
                let hasTag = meta.tags.contains { tag in
                    tag.key == required.key && tag.value == required.value
                }
                if !hasTag { return false }
            }
        }

        if !metadataFilter.requiredLabels.isEmpty {
            for label in metadataFilter.requiredLabels where !meta.labels.contains(label) {
                return false
            }
        }

        return true
    }

    private static func passesFrameFilter(
        meta: FrameMeta,
        frameId: UInt64,
        score: Float,
        request: SearchRequest,
        filter: FrameFilter
    ) -> Bool {
        if let minScore = request.minScore, score < minScore { return false }
        if let timeRange = request.timeRange, !timeRange.contains(meta.timestamp) { return false }
        if let allowlist = filter.frameIds, !allowlist.contains(frameId) { return false }
        if !filter.includeDeleted, meta.status == .deleted { return false }
        if !filter.includeSuperseded, meta.supersededBy != nil { return false }
        if !filter.includeSurrogates, FrameKind(rawKind: meta.kind) == .surrogate { return false }
        if let metadataFilter = filter.metadataFilter, !matches(metadataFilter: metadataFilter, meta: meta) {
            return false
        }
        return true
    }
}
