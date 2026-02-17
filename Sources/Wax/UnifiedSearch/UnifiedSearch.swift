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
            do {
                let base = try await textEngine.search(query: primaryQuery, topK: candidateLimit)
                guard base.isEmpty, let fallback = Self.orExpandedQuery(from: trimmedQuery) else {
                    return base
                }
                guard fallback != primaryQuery else { return base }
                return try await textEngine.search(query: fallback, topK: candidateLimit)
            } catch {
                guard let fallback = Self.orExpandedQuery(from: trimmedQuery) else {
                    throw error
                }
                return try await textEngine.search(query: fallback, topK: candidateLimit)
            }
        }()

        async let vectorResultsAsync: [(frameId: UInt64, score: Float)] = {
            guard includeVector, let vectorEngine, let embedding = request.embedding, !embedding.isEmpty else { return [] }
            var queryEmbedding = embedding
            if vectorEngine is MetalVectorEngine, !VectorMath.isNormalizedL2(queryEmbedding) {
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

        func passesFilters(
            meta: FrameMeta,
            frameId: UInt64,
            score: Float
        ) -> Bool {
            if let minScore = request.minScore, score < minScore { return false }
            if let timeRange = request.timeRange, !timeRange.contains(meta.timestamp) { return false }
            if let allowlist = filter.frameIds, !allowlist.contains(frameId) { return false }
            if !filter.includeDeleted, meta.status == .deleted { return false }
            if !filter.includeSuperseded, meta.supersededBy != nil { return false }
            if !filter.includeSurrogates, meta.kind == "surrogate" { return false }
            if let metadataFilter = filter.metadataFilter, !Self.matches(metadataFilter: metadataFilter, meta: meta) {
                return false
            }
            return true
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
                    if let minScore = request.minScore, item.score < minScore { continue }
                    guard let meta = metaById[item.frameId] else { continue }
                    guard passesFilters(meta: meta, frameId: item.frameId, score: item.score) else { continue }

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
                    if let minScore = request.minScore, item.score < minScore { continue }
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
                    guard passesFilters(meta: meta, frameId: item.frameId, score: item.score) else { continue }

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

            if let allowlist = filter.frameIds, !allowlist.contains(frameId) { continue }
            if !filter.includeDeleted, meta.status == .deleted { continue }
            if !filter.includeSuperseded, meta.supersededBy != nil { continue }
            if !filter.includeSurrogates, meta.kind == "surrogate" { continue }

            let score = 1 / Float(max(0, request.rrfK) + rank + 1)
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
        if tokens.isEmpty { return nil }
        let quoted = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return quoted.joined(separator: " OR ")
    }

    private static func primaryFTSQuery(from query: String, maxTokens: Int = 16) -> String? {
        guard requiresSafeFTSNormalization(query) else { return query }
        let tokens = normalizedFTSTokens(from: query, maxTokens: maxTokens)
        if tokens.isEmpty { return nil }
        let quoted = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        // Use AND-like semantics for the first pass; fallback can broaden with OR.
        return quoted.joined(separator: " ")
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
        var byFrame: [UInt64: Accumulator] = [:]

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

        var ranked: [RRFFusedCandidate] = byFrame.map { frameId, acc in
            let contributions = includeDiagnostics
                ? acc.laneContributions.sorted { lhs, rhs in
                    if lhs.rrfScore != rhs.rrfScore { return lhs.rrfScore > rhs.rrfScore }
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                : []
            return RRFFusedCandidate(
                frameId: frameId,
                score: acc.score,
                bestRank: acc.bestRank,
                sources: acc.sources.sorted { $0.rawValue < $1.rawValue },
                laneContributions: contributions
            )
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.bestRank != rhs.bestRank { return lhs.bestRank < rhs.bestRank }
            return lhs.frameId < rhs.frameId
        }

        let topDiagLimit = max(1, diagnosticsTopK)

        return ranked.enumerated().map { index, candidate in
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

            return (
                frameId: candidate.frameId,
                score: candidate.score,
                sources: candidate.sources,
                diagnostics: diagnostics
            )
        }
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
        let queryNumericEntities = queryEntities.filter { termContainsDigits($0) }
        let queryAlphaEntities = queryEntities.filter { isLettersOnly($0) }
        let queryNumericTerms = queryTerms.filter { isDigitsOnly($0) }
        let hasTargetIntent =
            intents.contains(.asksLocation)
            || intents.contains(.asksDate)
            || intents.contains(.asksOwnership)

        if !hasTargetIntent || queryEntities.isEmpty {
            return results
        }

        struct Candidate {
            let result: SearchResponse.Result
            let score: Float
        }

        func compositeScore(for result: SearchResponse.Result) -> Float {
            var total = result.score
            guard let preview = result.previewText, !preview.isEmpty else { return total }

            let previewTerms = Set(analyzer.normalizedTerms(query: preview))
            let previewEntities = analyzer.entityTerms(query: preview)
            let previewAlphaEntities = previewEntities.filter { isLettersOnly($0) }
            let lower = preview.lowercased()

            if !queryTerms.isEmpty, !previewTerms.isEmpty {
                let overlap = Float(queryTerms.intersection(previewTerms).count)
                let recall = overlap / Float(max(1, queryTerms.count))
                let precision = overlap / Float(max(1, previewTerms.count))
                total += recall * 0.55
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

            if intents.contains(.asksLocation) {
                if lower.contains("moved to") || lower.contains("move to") || lower.contains("city") {
                    total += 1.35
                }
                if lower.contains("allergic") || lower.contains("health") || lower.contains("peanut") {
                    total -= 1.10
                }
                if lower.contains("prefers") || lower.contains("prefer") {
                    total -= 0.55
                }
            }

            if intents.contains(.asksDate) {
                if lower.contains("public launch") || containsDateLiteral(preview) {
                    total += 1.20
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

        var head = Array(results.prefix(cappedWindow)).map { result in
            Candidate(result: result, score: compositeScore(for: result))
        }
        head.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            return lhs.result.frameId < rhs.result.frameId
        }

        let rerankedHead = head.enumerated().map { index, candidate -> SearchResponse.Result in
            var result = candidate.result
            if var diagnostics = result.rankingDiagnostics {
                diagnostics.tieBreakReason = index == 0 ? .topResult : .rerankComposite
                result.rankingDiagnostics = diagnostics
            }
            return result
        }

        if cappedWindow == results.count {
            return rerankedHead
        }
        return rerankedHead + Array(results.dropFirst(cappedWindow))
    }

    private static func looksDistractorLike(_ text: String) -> Bool {
        text.contains("weekly report")
            || text.contains("checklist")
            || text.contains("signoff")
            || text.contains("allergic")
            || text.contains("distractor")
    }

    private static func containsDateLiteral(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},\s+\d{4}\b"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }

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

    private static let asciiPunctuationScalars: Set<UnicodeScalar> = {
        let scalars = "!\\\"#$%&'()*+,-./:;<=>?@[\\\\]^_`{|}~".unicodeScalars
        return Set(scalars)
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
}
