import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

struct UnifiedSearchEngineOverrides {
    var textEngine: FTS5SearchEngine?
    var vectorEngine: (any VectorSearchEngine)?
    var structuredEngine: FTS5SearchEngine?
}

public extension Wax {
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

        let candidateLimit = Self.candidateLimit(for: requestedTopK)
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


        async let textResultsAsync: [TextSearchResult] = {
            guard includeText, let textEngine, let trimmedQuery, !trimmedQuery.isEmpty else { return [] }
            let primaryQuery = Self.primaryFTSQuery(from: trimmedQuery) ?? trimmedQuery
            let fallbackQuery = Self.orExpandedQuery(from: trimmedQuery)

            func merged(
                base: [TextSearchResult],
                fallback: [TextSearchResult],
                limit: Int
            ) -> [TextSearchResult] {
                guard !base.isEmpty else {
                    return Array(fallback.prefix(limit))
                }
                if base.count >= limit { return Array(base.prefix(limit)) }

                var seen = Set(base.map(\.frameId))
                var combined = base
                combined.reserveCapacity(limit)
                for candidate in fallback {
                    guard !seen.contains(candidate.frameId) else { continue }
                    combined.append(candidate)
                    seen.insert(candidate.frameId)
                    if combined.count >= limit { break }
                }
                return combined
            }

            do {
                let base = try await textEngine.search(query: primaryQuery, topK: candidateLimit)
                guard let fallbackQuery, fallbackQuery != primaryQuery else {
                    return Array(base.prefix(candidateLimit))
                }
                let fallback = try await textEngine.search(query: fallbackQuery, topK: candidateLimit)
                return merged(base: base, fallback: fallback, limit: candidateLimit)
            } catch {
                guard let fallbackQuery else {
                    throw error
                }
                return try await textEngine.search(query: fallbackQuery, topK: candidateLimit)
            }
        }()

        async let vectorResultsAsync: [(frameId: UInt64, score: Float)] = {
            guard includeVector, let vectorEngine, let embedding = request.embedding, !embedding.isEmpty else { return [] }
            var queryEmbedding = embedding
            #if canImport(Metal)
            let isMetalEngine = vectorEngine is MetalVectorEngine
            #else
            let isMetalEngine = false
            #endif
            if isMetalEngine, !VectorMath.isNormalizedL2(queryEmbedding) {
                queryEmbedding = VectorMath.normalizeL2(queryEmbedding)
            }
            return try await vectorEngine.search(vector: queryEmbedding, topK: candidateLimit)
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

            let asOfMs = request.timeRange?.before ?? request.asOfMs
            let asOf = StructuredMemoryAsOf(asOfMs: asOfMs)
            return try await structuredEngine.evidenceFrameIds(
                subjectKeys: candidates,
                asOf: asOf,
                maxFacts: options.maxFacts,
                maxFrames: options.maxEvidenceFrames,
                requireEvidenceSpan: options.requireEvidenceSpan
            )
        }()

        let textResults = try await textResultsAsync
        let vectorResults = try await vectorResultsAsync
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
                .filter { filter.includeSurrogates || $0.kind != "surrogate" }
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

        let baseResults: [BaseResult]
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
                        (source: .structuredMemory, weight: structuredWeight, frameIds: structuredIds),
                    ],
                    k: request.rrfK,
                    includeDiagnostics: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )

                baseResults = fused.map { entry in
                    let sources = entry.sources.isEmpty
                        ? (textSet.contains(entry.frameId) ? [.text] : [.structuredMemory])
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
                        (source: .structuredMemory, weight: structuredWeight, frameIds: structuredIds),
                    ],
                    k: request.rrfK,
                    includeDiagnostics: diagnosticsEnabled,
                    diagnosticsTopK: diagnosticsTopK
                )

                baseResults = fused.map { entry in
                    let sources = entry.sources.isEmpty
                        ? (vectorSet.contains(entry.frameId) ? [.vector] : [.structuredMemory])
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
            if structuredWeight > 0, !structuredIds.isEmpty { lists.append((source: .structuredMemory, weight: structuredWeight, frameIds: structuredIds)) }

            let fused = Self.rrfFusionResults(
                lists: lists,
                k: request.rrfK,
                includeDiagnostics: diagnosticsEnabled,
                diagnosticsTopK: diagnosticsTopK
            )

            let timelineSet = Set(timelineIds)
            let structuredSet = Set(structuredIds)

            baseResults = fused.map { entry in
                var sources = entry.sources
                if sources.isEmpty {
                    if textSet.contains(entry.frameId) { sources.append(.text) }
                    if vectorSet.contains(entry.frameId) { sources.append(.vector) }
                    if timelineSet.contains(entry.frameId) { sources.append(.timeline) }
                    if structuredSet.contains(entry.frameId) { sources.append(.structuredMemory) }
                }
                return BaseResult(
                    frameId: entry.frameId,
                    score: entry.score,
                    sources: sources,
                    rankingDiagnostics: entry.diagnostics
                )
            }
        }


        struct PendingResult {
            let frameId: UInt64
            let score: Float
            let sources: [SearchResponse.Source]
            let snippet: String?
            let rankingDiagnostics: SearchResponse.RankingDiagnostics?
        }

        var pendingResults: [PendingResult] = []
        pendingResults.reserveCapacity(min(requestedTopK, baseResults.count))

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
                            rankingDiagnostics: item.rankingDiagnostics
                        )
                    )

                    if pendingResults.count >= requestedTopK {
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
                            rankingDiagnostics: item.rankingDiagnostics
                        )
                    )

                    if pendingResults.count >= requestedTopK {
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
                rankingDiagnostics: rankingDiagnostics
            )
        }

        if let trimmedQuery, !trimmedQuery.isEmpty {
            filtered = Self.intentAwareRerank(
                results: filtered,
                query: trimmedQuery,
                maxWindow: min(max(request.topK * 2, 10), 32)
            )
        }

        if filtered.isEmpty, request.allowTimelineFallback {
            filtered = await timelineFallbackResults(request: request, filter: filter)
        }

        return SearchResponse(results: filtered)
    }

    private func timelineFallbackResults(request: SearchRequest, filter: FrameFilter) async -> [SearchResponse.Result] {
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
                    sources: [.timeline]
                )
            )

            if results.count >= request.timelineFallbackLimit {
                break
            }
        }

        return results
    }

    private static func orExpandedQuery(from query: String, maxTokens: Int = 16) -> String? {
        let tokens = normalizedFTSTokens(from: query, maxTokens: maxTokens)
        let quotedTokens = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        let quotedPhrases = normalizedQuotedPhrases(from: query).map { phrase -> String in
            let escaped = phrase.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        let clauses = quotedPhrases + quotedTokens
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " OR ")
    }

    private static func primaryFTSQuery(from query: String, maxTokens: Int = 16) -> String? {
        guard requiresSafeFTSNormalization(query) else { return query }
        let tokens = normalizedFTSTokens(from: query, maxTokens: maxTokens)
        let quotedTokens = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        let quotedPhrases = normalizedQuotedPhrases(from: query).map { phrase -> String in
            let escaped = phrase.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        let clauses = quotedPhrases + quotedTokens
        guard !clauses.isEmpty else { return nil }
        // Use AND-like semantics for the first pass; fallback can broaden with OR.
        return clauses.joined(separator: " ")
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

    private static func intentAwareRerank(
        results: [SearchResponse.Result],
        query: String,
        maxWindow: Int,
        analyzer: QueryAnalyzer = QueryAnalyzer()
    ) -> [SearchResponse.Result] {
        let cappedWindow = min(max(0, maxWindow), results.count)
        guard cappedWindow > 1 else { return results }

        let intents = analyzer.detectIntent(query: query)
        let queryTerms = Set(analyzer.normalizedTerms(query: query))
        let queryEntities = analyzer.entityTerms(query: query)
        let queryYears = analyzer.yearTerms(in: query)
        let queryDateKeys = analyzer.normalizedDateKeys(in: query)
        let rawPhrases = rawQuotedPhrases(from: query)
        let lowerRawPhrases = rawPhrases.map { $0.lowercased() }
        let normalizedPhrases = normalizedQuotedPhrases(from: query)
        let queryNumericEntities = queryEntities.filter { termContainsDigits($0) }
        let queryAlphaEntities = queryEntities.filter { isLettersOnly($0) }
        let queryNumericTerms = queryTerms.filter { isDigitsOnly($0) }
        let hasTargetIntent =
            intents.contains(.asksLocation)
            || intents.contains(.asksDate)
            || intents.contains(.asksOwnership)

        let hasDisambiguationSignals =
            !queryEntities.isEmpty
            || !queryYears.isEmpty
            || !queryDateKeys.isEmpty
            || !rawPhrases.isEmpty
            || !normalizedPhrases.isEmpty

        if !hasTargetIntent || !hasDisambiguationSignals {
            return results
        }

        // Scoring weights calibrated for search-result reranking (UnifiedSearch output).
        // These intentionally differ from FastRAGContextBuilder.rerankCandidatesForAnswer:
        //   - Lower recall/precision weights (0.55/0.25 vs 0.80/0.40) — search results
        //     show previews where false positives are more visible to users.
        //   - Separate numeric/alpha entity scoring with higher numeric weight (1.95) —
        //     search queries often disambiguate via IDs like "person18" or "atlas10".
        //   - Broader distractor detection (looksDistractorLike) — search results page
        //     needs wider filtering since items aren't further filtered by a context builder.
        func compositeScore(for result: SearchResponse.Result) -> Float {
            var total = result.score
            guard let preview = result.previewText, !preview.isEmpty else { return total }

            let comparablePreview = dehighlightedPreviewText(preview)
            let previewTerms = Set(analyzer.normalizedTerms(query: comparablePreview))
            let previewEntities = analyzer.entityTerms(query: comparablePreview)
            let previewYears = analyzer.yearTerms(in: comparablePreview)
            let previewDateKeys = analyzer.normalizedDateKeys(in: comparablePreview)
            let previewAlphaEntities = previewEntities.filter { isLettersOnly($0) }
            let lower = comparablePreview.lowercased()
            let normalizedLower = normalizedPhraseComparableText(comparablePreview)
            let vectorInfluenced = result.sources.contains(.vector)

            if !queryTerms.isEmpty, !previewTerms.isEmpty {
                let overlap = Float(queryTerms.intersection(previewTerms).count)
                let recall = overlap / Float(max(1, queryTerms.count))
                let precision = overlap / Float(max(1, previewTerms.count))
                total += recall * 0.55   // Lower than FastRAG: false positives more visible in search UI
                total += precision * 0.25
            }

            if !queryEntities.isEmpty {
                let entityHits = queryEntities.intersection(previewEntities).count
                let coverage = Float(entityHits) / Float(max(1, queryEntities.count))
                if !queryNumericEntities.isEmpty {
                    let numericHits = queryNumericEntities.intersection(previewEntities).count
                    let numericCoverage = Float(numericHits) / Float(max(1, queryNumericEntities.count))
                    total += numericCoverage * 1.95
                }
                if !queryAlphaEntities.isEmpty {
                    let alphaHits = queryAlphaEntities.intersection(previewAlphaEntities).count
                    let alphaCoverage = Float(alphaHits) / Float(max(1, queryAlphaEntities.count))
                    total += alphaCoverage * 1.25
                }
                total += coverage * 0.30
                if entityHits == 0 {
                    total -= !queryNumericEntities.isEmpty ? 0.85 : 0.45
                    if !queryNumericTerms.isEmpty,
                       !queryNumericTerms.intersection(previewTerms).isEmpty {
                        total -= 0.75
                    }
                }
                if !queryAlphaEntities.isEmpty,
                   queryAlphaEntities.intersection(previewAlphaEntities).isEmpty,
                   !previewAlphaEntities.isEmpty {
                    total -= 0.40
                }
            }

            if !queryYears.isEmpty {
                let yearHits = queryYears.intersection(previewYears).count
                let yearCoverage = Float(yearHits) / Float(max(1, queryYears.count))
                total += yearCoverage * 1.25
                if yearHits == 0, !previewYears.isEmpty {
                    total -= 1.10
                }
            }

            if !queryDateKeys.isEmpty {
                let dateHits = queryDateKeys.intersection(previewDateKeys).count
                let dateCoverage = Float(dateHits) / Float(max(1, queryDateKeys.count))
                total += dateCoverage * 1.15
                if dateHits == 0, !previewDateKeys.isEmpty {
                    total -= 0.95
                }
            }

            let strictRawPhrases = lowerRawPhrases.filter { phrase in
                phrase.contains("-") || phrase.split(whereSeparator: \.isWhitespace).count >= 2
            }
            var exactPhraseHits = 0
            var strictExactHits = 0
            if !lowerRawPhrases.isEmpty {
                for phrase in lowerRawPhrases where lower.contains(phrase) {
                    exactPhraseHits += 1
                }
                for phrase in strictRawPhrases where lower.contains(phrase) {
                    strictExactHits += 1
                }
                let strictPhraseIntent = !strictRawPhrases.isEmpty
                if exactPhraseHits > 0 {
                    total += Float(exactPhraseHits) * (strictPhraseIntent ? 2.10 : 1.20)
                } else {
                    total -= strictPhraseIntent ? 1.40 : 0.35
                }
                let strictMisses = strictRawPhrases.count - strictExactHits
                if strictMisses > 0 {
                    total -= Float(strictMisses) * 0.85
                }
            }

            if !normalizedPhrases.isEmpty {
                var normalizedHits = 0
                for phrase in normalizedPhrases where normalizedLower.contains(phrase) {
                    normalizedHits += 1
                }
                let coverage = Float(normalizedHits) / Float(max(1, normalizedPhrases.count))
                let strictPhraseMiss = !strictRawPhrases.isEmpty && strictExactHits == 0
                total += coverage * (strictPhraseMiss ? 0.20 : 0.75)
                if strictPhraseMiss {
                    total -= 0.55
                }
                if normalizedHits == 0 {
                    total -= strictPhraseMiss ? 0.45 : 0.20
                }
            }

            if intents.contains(.asksLocation) {
                if containsMovedToLocationPattern(comparablePreview) {
                    total += 1.60
                } else if lower.contains("moved to") || lower.contains("move to") {
                    total += 0.45
                } else if lower.contains("city") {
                    total += 0.10
                }
                if lower.contains("without a destination")
                    || lower.contains("city move")
                    || lower.contains("retrospective")
                {
                    total -= 0.75
                }
                if lower.contains("allergic") || lower.contains("health") || lower.contains("peanut") {
                    total -= 1.10
                }
                if lower.contains("prefers") || lower.contains("prefer") {
                    total -= 0.55
                }
            }

            if intents.contains(.asksDate) {
                let tentative = RerankingHelpers.containsTentativeLaunchLanguage(lower)
                if lower.contains("public launch is"), !tentative {
                    total += 1.70
                } else if lower.contains("public launch") || analyzer.containsDateLiteral(comparablePreview) {
                    total += 1.20
                }
                if tentative {
                    let scaledPenalty = max(
                        vectorInfluenced ? 2.90 : 2.45,
                        result.score * (vectorInfluenced ? 1.60 : 1.40)
                    )
                    total -= scaledPenalty
                }
                if lower.contains("draft memo") {
                    total -= vectorInfluenced ? 1.45 : 1.20
                }
                if lower.contains(" owns ") || lower.contains("owner") || lower.contains("deployment readiness") {
                    total -= 0.40
                }
            }

            if intents.contains(.asksOwnership) {
                if lower.contains(" owns ")
                    || lower.contains("owner")
                    || lower.contains("owns deployment readiness")
                {
                    total += 1.10
                }
                if lower.contains("public launch") && !lower.contains(" owns ") {
                    total -= 0.35
                }
            }

            if looksDistractorLike(lower) {
                total -= 0.40
            }

            return total
        }

        var scoredHead: [(index: Int, score: Float)] = []
        scoredHead.reserveCapacity(cappedWindow)
        for index in 0..<cappedWindow {
            let result = results[index]
            scoredHead.append((index: index, score: compositeScore(for: result)))
        }
        scoredHead.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsResult = results[lhs.index]
            let rhsResult = results[rhs.index]
            if lhsResult.score != rhsResult.score { return lhsResult.score > rhsResult.score }
            return lhsResult.frameId < rhsResult.frameId
        }

        var rerankedHead: [SearchResponse.Result] = []
        rerankedHead.reserveCapacity(cappedWindow)
        for (rank, candidate) in scoredHead.enumerated() {
            var result = results[candidate.index]
            if var diagnostics = result.rankingDiagnostics {
                diagnostics.tieBreakReason = rank == 0 ? .topResult : .rerankComposite
                result.rankingDiagnostics = diagnostics
            }
            rerankedHead.append(result)
        }

        if cappedWindow == results.count {
            return rerankedHead
        }
        var combined = rerankedHead
        combined.reserveCapacity(results.count)
        combined.append(contentsOf: results.dropFirst(cappedWindow))
        return combined
    }

    /// UnifiedSearch distractor check — broader than FastRAGContextBuilder.looksDistractor.
    /// Includes "allergic", "draft memo", "tentative", "pending approval" because UnifiedSearch
    /// needs wider filtering for search result quality. Omits "no authoritative" (only relevant
    /// for answer-focused context assembly where confidence-undermining language matters).
    private static func looksDistractorLike(_ text: String) -> Bool {
        text.contains("weekly report")
            || text.contains("checklist")
            || text.contains("signoff")
            || text.contains("allergic")
            || text.contains("distractor")
            || text.contains("draft memo")
            || text.contains("tentative")
            || text.contains("pending approval")
    }

    // containsTentativeLaunchLanguage → RerankingHelpers (shared with FastRAGContextBuilder)

    private static let movedToLocationRegex = try? NSRegularExpression(
        pattern: #"\b(?:moved|move)\s+to\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b"#
    )

    private static func containsMovedToLocationPattern(_ text: String) -> Bool {
        guard let regex = movedToLocationRegex else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // containsDateLiteral → use analyzer.containsDateLiteral() directly (avoids throwaway QueryAnalyzer)

    private static func isDigitsOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isLettersOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func termContainsDigits(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private static func requiresSafeFTSNormalization(_ query: String) -> Bool {
        query.unicodeScalars.contains { scalar in
            scalar.isASCII && asciiPunctuationScalars.contains(scalar)
        }
    }

    private static let ftsStopWords: Set<String> = [
        "a", "an", "and", "are", "at", "did", "do", "for", "from", "in", "is", "of",
        "on", "or", "the", "to", "what", "when", "where", "which", "who", "with",
        "date",
    ]

    private static func normalizedFTSTokens(from query: String, maxTokens: Int) -> [String] {
        let capped = max(0, maxTokens)
        guard capped > 0 else { return [] }
        var seen: Set<String> = []
        var tokens: [String] = []
        tokens.reserveCapacity(capped)

        for token in structuredAliasTokens(from: query) {
            let normalized = token.lowercased()
            guard !normalized.isEmpty else { continue }
            guard !ftsStopWords.contains(normalized) else { continue }
            let hasLettersOrDigits = normalized.unicodeScalars.contains {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            guard hasLettersOrDigits else { continue }
            if seen.insert(normalized).inserted {
                tokens.append(normalized)
                if tokens.count >= capped { break }
            }
        }

        return tokens
    }

    private static func rawQuotedPhrases(from query: String, maxPhrases: Int = 4) -> [String] {
        let range = NSRange(location: 0, length: query.utf16.count)
        var matches: [(location: Int, phrase: String)] = []

        for regex in quotedPhraseRegexes {
            for match in regex.matches(in: query, range: range) {
                let capture = match.range(at: 1)
                guard capture.location != NSNotFound,
                      let swiftRange = Range(capture, in: query)
                else {
                    continue
                }
                let phrase = query[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { continue }
                matches.append((location: capture.location, phrase: String(phrase)))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.phrase.count < rhs.phrase.count
        }

        var seen: Set<String> = []
        var phrases: [String] = []
        phrases.reserveCapacity(min(maxPhrases, matches.count))
        for match in matches {
            guard phrases.count < maxPhrases else { break }
            let hasSignal = match.phrase.unicodeScalars.contains {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            guard hasSignal else { continue }
            let key = match.phrase.lowercased()
            if seen.insert(key).inserted {
                phrases.append(match.phrase)
            }
        }
        return phrases
    }

    private static func normalizedQuotedPhrases(
        from query: String,
        maxPhrases: Int = 4,
        maxTokensPerPhrase: Int = 8
    ) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for phrase in rawQuotedPhrases(from: query, maxPhrases: maxPhrases) {
            let tokens = normalizedFTSTokens(from: phrase, maxTokens: maxTokensPerPhrase)
            guard !tokens.isEmpty else { continue }
            let value = tokens.joined(separator: " ")
            if seen.insert(value).inserted {
                normalized.append(value)
            }
        }

        return normalized
    }

    private static func normalizedPhraseComparableText(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: " ")
    }

    private static func dehighlightedPreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    private static let asciiPunctuationScalars: Set<UnicodeScalar> = {
        let scalars = "!\\\"#$%&'()*+,-./:;<=>?@[\\\\]^_`{|}~".unicodeScalars
        return Set(scalars)
    }()

    private static let quotedPhraseRegexes: [NSRegularExpression] = {
        let patterns = [
            #""([^"]+)""#,
            #"'([^']+)'"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

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

        let tokens = structuredAliasTokens(from: query)
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

    private static func structuredAliasTokens(from query: String) -> [String] {
        var tokens: [String] = []
        var buffer = String.UnicodeScalarView()

        func flush() {
            if !buffer.isEmpty {
                tokens.append(String(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in query.unicodeScalars {
            if scalar.properties.isWhitespace || (scalar.isASCII && asciiPunctuationScalars.contains(scalar)) {
                flush()
            } else {
                buffer.append(scalar)
            }
        }
        flush()

        return tokens
    }

    private static func candidateLimit(for topK: Int) -> Int {
        guard topK > 0 else { return 0 }
        let expanded = topK > Int.max / 3 ? Int.max : topK * 3
        let capped = min(expanded, 1000)
        return max(topK, capped)
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
        if !filter.includeSurrogates, meta.kind == "surrogate" { return false }
        if let metadataFilter = filter.metadataFilter, !matches(metadataFilter: metadataFilter, meta: meta) {
            return false
        }
        return true
    }
}
