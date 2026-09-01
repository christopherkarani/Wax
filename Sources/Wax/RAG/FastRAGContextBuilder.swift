import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

package struct FastRAGContextBuilder: Sendable {
    package init() {}

    /// Build a deterministic RAG context: at most one expansion + ranked snippets.
    /// - Parameters:
    ///   - query: user query string
    ///   - embedding: optional caller-supplied embedding (no query-time embedding inside Wax)
    ///   - wax: Wax handle
    ///   - config: Fast RAG configuration
    package func build(
        query: String,
        embedding: [Float]? = nil,
        vectorEnginePreference: VectorEnginePreference = .auto,
        wax: Wax,
        session: WaxSession? = nil,
        frameFilter: FrameFilter? = nil,
        timeRange: SearchTimeRange? = nil,
        scopeContext: MemoryScopeContext? = nil,
        accessStatsManager: AccessStatsManager? = nil,
        config: FastRAGConfig = .init()
    ) async throws -> RAGContext {
        let clamped = clamp(config)
        let counter = try await TokenCounter.shared()

        // 1) Run unified search
        // Access-aware ranking needs a little headroom so a stale top result can
        // be displaced by a recently/frequently used candidate just outside the
        // normal context window. The bound keeps enabled-mode work predictable.
        let searchTopK: Int
        if accessStatsManager == nil {
            searchTopK = clamped.searchTopK
        } else if clamped.searchTopK <= 24 {
            searchTopK = clamped.searchTopK * 2
        } else {
            searchTopK = clamped.searchTopK
        }
        let request = SearchRequest(
            query: query,
            embedding: embedding,
            vectorEnginePreference: vectorEnginePreference,
            mode: clamped.searchMode,
            topK: searchTopK,
            timeRange: timeRange,
            frameFilter: frameFilter,
            nowMs: clamped.deterministicNowMs ?? Int64(Date().timeIntervalSince1970 * 1000),
            scopeContext: scopeContext,
            rrfK: clamped.rrfK,
            previewMaxBytes: clamped.previewMaxBytes
        )
        let response = if let session {
            try await session.search(request)
        } else {
            try await wax.search(request)
        }
        let scoringMetadata: [UInt64: FrameMeta] = if accessStatsManager != nil,
                                                        clamped.deterministicNowMs == nil {
            await wax.frameMetas(frameIds: response.results.map(\.frameId))
        } else {
            [:]
        }
        let accessScoringNowMs = clamped.deterministicNowMs
            ?? scoringMetadata.values.map(\.timestamp).max()
            ?? 0
        let accessStatsMap: [UInt64: FrameAccessStats] = if let accessStatsManager {
            await AccessFrequencyRanker.statsForRanking(
                frameIds: response.results.map(\.frameId),
                manager: accessStatsManager,
                wax: wax
            )
        } else {
            [:]
        }
        let accessRankedResults = accessStatsManager == nil
            ? response.results
            : AccessFrequencyRanker.rerank(
                results: response.results,
                query: query,
                accessStats: accessStatsMap,
                nowMs: accessScoringNowMs,
                maxWindow: searchTopK
            )
        let queryAnalyzer = QueryAnalyzer()
        let rankedResults = clamped.enableAnswerFocusedRanking
            ? Self.orderCandidatesForAnswer(
                results: accessRankedResults,
                query: query,
                config: clamped,
                analyzer: queryAnalyzer
            )
            : accessRankedResults
        // The search request may be overfetched only to give access-aware
        // reranking headroom. Context assembly still honors the caller's
        // requested result count.
        let contextResults = Array(rankedResults.prefix(max(0, clamped.searchTopK)))

        // Pre-compute query signals for tier selection if enabled
        let querySignals: QuerySignals? = clamped.enableQueryAwareTierSelection
            ? queryAnalyzer.analyze(query: query)
            : nil
        let queryIntent = queryAnalyzer.detectIntent(query: query)

        // Prefetch surrogate metadata in parallel with expansion work.
        // This keeps determinism while overlapping Wax actor hops.
        let shouldPrefetchSurrogates = clamped.mode == .denseCached
            && clamped.maxSurrogates > 0
            && clamped.surrogateMaxTokens > 0
            && clamped.maxContextTokens > 0
        let sourceFrameIds = contextResults.map { $0.frameId }
        let surrogateMapTask: [UInt64: UInt64] = shouldPrefetchSurrogates
            ? await wax.surrogateFrameIds(for: sourceFrameIds)
            : [:]
        let sourceFrameMetasTask: [UInt64: FrameMeta] = shouldPrefetchSurrogates
            ? await wax.frameMetas(frameIds: sourceFrameIds)
            : [:]

        // nowMs resolution order:
        // 1. deterministicNowMs if explicitly set (always the case when called via MemoryOrchestrator.recall)
        // 2. max frame timestamp — provides a stable, deterministic "now" for direct callers
        //    that have not set deterministicNowMs (e.g., tests). Note: this may understate
        //    recency for stores where all frames are old relative to wall clock.
        // Both values derive from store state, so tier selection and access-recency
        // explanations stay deterministic. When neither source exists, nowMs stays nil:
        // unknown-now produces no access-recency signal (access-reason enrichment is
        // skipped) instead of a maximal "recently used" signal from a zero sentinel,
        // and surrogate tiers keep full fidelity rather than a fabricated zero age.
        let nowMs = clamped.deterministicNowMs
            ?? sourceFrameMetasTask.values.map(\.timestamp).max()

        var expansionTextByFrame: [UInt64: String] = [:]
        var expandedSourceFrameId: UInt64?
        if clamped.expansionMaxTokens > 0, clamped.expansionMaxBytes > 0 {
            for result in contextResults {
                if let expanded = try await expansionText(
                    frameId: result.frameId,
                    wax: wax,
                    maxBytes: clamped.expansionMaxBytes
                ) {
                    expansionTextByFrame[result.frameId] = expanded
                    expandedSourceFrameId = result.frameId
                    break
                }
            }
        }

        var surrogateBySource: [UInt64: (frameId: UInt64, text: String)] = [:]
        if clamped.mode == .denseCached,
           clamped.maxContextTokens > 0,
           clamped.maxSurrogates > 0,
           clamped.surrogateMaxTokens > 0 {
            let estimatedExpansionTokens = expansionTextByFrame.isEmpty ? 0 : min(
                clamped.expansionMaxTokens,
                clamped.maxContextTokens
            )
            let remainingTokens = max(0, clamped.maxContextTokens - estimatedExpansionTokens)
            let estimatedTokensPerSurrogate = max(1, clamped.surrogateMaxTokens / 2)
            let estimatedMaxSurrogates = max(1, remainingTokens / estimatedTokensPerSurrogate)
            let maxToLoad = min(
                clamped.maxSurrogates,
                min(clamped.searchTopK, 32),
                estimatedMaxSurrogates + 2
            )

            // Batch resolve surrogate ids in a single actor hop to avoid TaskGroup churn.
            let surrogateMap = surrogateMapTask
            let expandedFrameId = expandedSourceFrameId

            // Keep only the top candidates, preserving response order.
            var orderedSurrogateIds: [UInt64] = []
            orderedSurrogateIds.reserveCapacity(maxToLoad)
            for result in contextResults {
                if let expandedFrameId, result.frameId == expandedFrameId { continue }
                guard let surrogateId = surrogateMap[result.frameId] else { continue }
                orderedSurrogateIds.append(surrogateId)
                if orderedSurrogateIds.count >= maxToLoad { break }
            }

            // Batch load surrogate contents to avoid per-frame actor hops.
            // If any surrogate is corrupted, fall back to per-frame loads and skip failures.
            let surrogateContents: [UInt64: Data] = await {
                do {
                    return try await wax.frameContents(frameIds: orderedSurrogateIds)
                } catch {
                    var recovered: [UInt64: Data] = [:]
                    recovered.reserveCapacity(orderedSurrogateIds.count)
                    for surrogateId in orderedSurrogateIds {
                        do {
                            let data = try await wax.frameContent(frameId: surrogateId)
                            recovered[surrogateId] = data
                        } catch {
                            WaxDiagnostics.logSwallowed(
                                error,
                                context: "surrogate frame content load",
                                fallback: "skip surrogate candidate"
                            )
                        }
                    }
                    return recovered
                }
            }()

            let tierSelector = SurrogateTierSelector(
                policy: clamped.tierSelectionPolicy,
                scorer: ImportanceScorer()
            )
            let frameMetaMap = sourceFrameMetasTask
            let surrogateWorkItems = contextResults
                .compactMap { result -> (result: SearchResponse.Result, surrogateFrameId: UInt64)? in
                    if let expandedFrameId, result.frameId == expandedFrameId { return nil }
                    guard let surrogateId = surrogateMap[result.frameId] else { return nil }
                    return (result: result, surrogateFrameId: surrogateId)
                }
                .prefix(maxToLoad)

            var surrogateCandidates = Array<(result: SearchResponse.Result, surrogateFrameId: UInt64, text: String)?>(
                repeating: nil,
                count: surrogateWorkItems.count
            )

            await withTaskGroup(of: (Int, (SearchResponse.Result, UInt64, String)?).self) { group in
                for (index, item) in surrogateWorkItems.enumerated() {
                    group.addTask {
                        guard let data = surrogateContents[item.surrogateFrameId] else { return (index, nil) }

                        let selectedTier: SurrogateTier
                        if let nowMs {
                            let frameTimestamp = frameMetaMap[item.result.frameId]?.timestamp ?? nowMs
                            let context = TierSelectionContext(
                                frameTimestamp: frameTimestamp,
                                accessStats: accessStatsMap[item.result.frameId],
                                querySignals: querySignals,
                                nowMs: nowMs
                            )
                            selectedTier = tierSelector.selectTier(context: context)
                        } else {
                            // Unknown "now": no age/recency basis for compression.
                            selectedTier = .full
                        }
                        guard let text = SurrogateTierSelector.extractTier(from: data, tier: selectedTier),
                              !text.isEmpty else { return (index, nil) }

                        return (index, (item.result, item.surrogateFrameId, text))
                    }
                }

                for await (index, candidate) in group {
                    surrogateCandidates[index] = candidate
                }
            }

            for (result, surrogateFrameId, text) in surrogateCandidates.compactMap({ $0 }) {
                surrogateBySource[result.frameId] = (surrogateFrameId, text)
            }
        }

        var snippetTextByFrame: [UInt64: String] = [:]
        if clamped.maxContextTokens > 0, clamped.snippetMaxTokens > 0, clamped.maxSnippets > 0 {
            var snippetCandidates: [(result: SearchResponse.Result, preview: String)] = []
            snippetCandidates.reserveCapacity(min(clamped.maxSnippets, 32))
            for result in contextResults {
                if expansionTextByFrame[result.frameId] != nil { continue }
                if surrogateBySource[result.frameId] != nil { continue }
                guard snippetCandidates.count < clamped.maxSnippets else { break }
                guard let preview = result.previewText, !preview.isEmpty else { continue }
                snippetCandidates.append((result, preview))
            }

            if !snippetCandidates.isEmpty {
                let snippetFallbackMaxBytes = min(
                    clamped.expansionMaxBytes,
                    max(4 * 1024, clamped.previewMaxBytes * 64)
                )
                var previews = Array<String>(repeating: "", count: snippetCandidates.count)
                await withTaskGroup(of: (Int, String).self) { group in
                    for (index, (result, preview)) in snippetCandidates.enumerated() {
                        group.addTask {
                            guard Self.shouldUseFullFrameForSnippet(preview: preview, intent: queryIntent, analyzer: queryAnalyzer) else {
                                return (index, preview)
                            }
                            do {
                                if let expanded = try await expansionText(
                                    frameId: result.frameId,
                                    wax: wax,
                                    maxBytes: snippetFallbackMaxBytes
                                ),
                                !expanded.isEmpty {
                                    return (index, expanded)
                                }
                            } catch {
                                WaxDiagnostics.logSwallowed(
                                    error,
                                    context: "snippet full-frame expansion",
                                    fallback: "keep preview snippet"
                                )
                            }
                            return (index, preview)
                        }
                    }

                    for await (index, text) in group {
                        previews[index] = text
                    }
                }

                for (index, (result, _)) in snippetCandidates.enumerated() {
                    snippetTextByFrame[result.frameId] = previews[index]
                }
            }
        }

        var payloads: [RecallAssembly.Payload] = []
        payloads.reserveCapacity(contextResults.count)
        for result in contextResults {
            let surrogate = surrogateBySource[result.frameId]
            payloads.append(
                RecallAssembly.Payload(
                    hit: result,
                    expansionText: expansionTextByFrame[result.frameId],
                    surrogateText: surrogate?.text,
                    snippetText: snippetTextByFrame[result.frameId] ?? result.previewText ?? "",
                    surrogateFrameId: surrogate?.frameId,
                    accessStats: accessStatsMap[result.frameId]
                )
            )
        }

        let tokenizer = RecallAssembly.Tokenizer(
            count: { text in await counter.count(text) },
            truncate: { text, maxTokens in await counter.truncate(text, maxTokens: maxTokens) }
        )
        return await RecallAssembly.pack(
            query: query,
            payloads: payloads,
            config: clamped,
            tokenizer: tokenizer,
            nowMs: nowMs
        )
    }

    // MARK: - Helpers

    private func clamp(_ config: FastRAGConfig) -> FastRAGConfig {
        var c = config
        c.maxContextTokens = max(0, c.maxContextTokens)
        c.expansionMaxTokens = min(max(0, c.expansionMaxTokens), c.maxContextTokens)
        c.expansionMaxBytes = max(0, c.expansionMaxBytes)
        c.snippetMaxTokens = max(0, c.snippetMaxTokens)
        c.maxSnippets = max(0, c.maxSnippets)
        c.maxSurrogates = max(0, c.maxSurrogates)
        c.surrogateMaxTokens = max(0, c.surrogateMaxTokens)
        c.searchTopK = max(0, c.searchTopK)
        c.rrfK = max(0, c.rrfK)
        c.previewMaxBytes = max(0, c.previewMaxBytes)
        c.answerRerankWindow = max(0, c.answerRerankWindow)
        c.answerDistractorPenalty = min(1, max(0, c.answerDistractorPenalty))
        return c
    }

    static func shouldUseFullFrameForSnippet(preview: String, intent: QueryIntent, analyzer: QueryAnalyzer) -> Bool {
        if preview.isEmpty { return false }
        let lower = preview.lowercased()

        // FTS5 snippet() truncates with '...' and wraps matched tokens in brackets.
        // Short durable memories (preferences, tokens, mission codes) often lose their
        // trailing identifiers in secondary hits. Expand to full frame content whenever
        // the preview shows truncation so Memory.search returns complete short texts.
        if preview.contains("...") {
            return true
        }

        if intent.contains(.asksDate) {
            let hintsTemporal = lower.contains("launch")
                || lower.contains("appointment")
                || lower.contains("beta")
                || lower.contains("timeline")
            if hintsTemporal && !analyzer.containsDateLiteral(preview) {
                return true
            }
        }

        if intent.contains(.asksOwnership),
           lower.contains("owns"),
           !lower.contains("deployment readiness") {
            return true
        }

        return false
    }

    /// Reorder already-ranked hits for an answer budget. Does not rewrite Ranking's published score.
    static func orderCandidatesForAnswer(
        results: [SearchResponse.Result],
        query: String,
        config: FastRAGConfig,
        analyzer: QueryAnalyzer = QueryAnalyzer()
    ) -> [SearchResponse.Result] {
        let cappedWindow = min(max(0, config.answerRerankWindow), results.count)
        guard cappedWindow > 1 else { return results }

        let intents = analyzer.detectIntent(query: query)
        let queryTerms = Set(analyzer.normalizedTerms(query: query))
        let queryEntities = analyzer.entityTerms(query: query)
        let queryYears = analyzer.yearTerms(in: query)
        let queryDateKeys = analyzer.normalizedDateKeys(in: query)
        let vectorInfluenced: Bool
        switch config.searchMode {
        case .vectorOnly:
            vectorInfluenced = true
        case .hybrid(let alpha):
            vectorInfluenced = alpha < 0.999
        case .textOnly:
            vectorInfluenced = false
        }
        if intents.isEmpty && queryTerms.isEmpty {
            return results
        }

        // Composite is only a sort key. Result.score stays Ranking's published score.
        func sortKey(_ result: SearchResponse.Result) -> Float {
            var total = result.score
            guard let preview = result.previewText, !preview.isEmpty else { return total }

            let previewLower = preview.lowercased()
            let previewTerms = Set(analyzer.normalizedTerms(query: preview))
            let previewEntities = analyzer.entityTerms(query: preview)
            let previewYears = analyzer.yearTerms(in: preview)
            let previewDateKeys = analyzer.normalizedDateKeys(in: preview)
            if !queryTerms.isEmpty, !previewTerms.isEmpty {
                let overlap = Float(queryTerms.intersection(previewTerms).count)
                let recall = overlap / Float(max(1, queryTerms.count))
                let precision = overlap / Float(max(1, previewTerms.count))
                total += recall * 0.80
                total += precision * 0.40
            }

            if !queryEntities.isEmpty {
                let hits = queryEntities.intersection(previewEntities).count
                let coverage = Float(hits) / Float(max(1, queryEntities.count))
                total += coverage * (vectorInfluenced ? 1.25 : 0.90)
                if hits == 0 {
                    total -= vectorInfluenced ? 0.65 : 0.35
                }
            }

            if !queryYears.isEmpty {
                let yearHits = queryYears.intersection(previewYears).count
                let yearCoverage = Float(yearHits) / Float(max(1, queryYears.count))
                total += yearCoverage * 1.35
                if yearHits == 0, !previewYears.isEmpty {
                    total -= vectorInfluenced ? 1.35 : 1.05
                }
            }

            if !queryDateKeys.isEmpty {
                let dateHits = queryDateKeys.intersection(previewDateKeys).count
                let dateCoverage = Float(dateHits) / Float(max(1, queryDateKeys.count))
                total += dateCoverage * 1.15
                if dateHits == 0, !previewDateKeys.isEmpty {
                    total -= vectorInfluenced ? 1.15 : 0.90
                }
            }

            if intents.contains(.asksLocation),
               previewLower.contains("moved to") {
                total += 0.45
            }
            if intents.contains(.asksDate),
               (previewLower.contains("public launch") || previewLower.contains("launch is") || analyzer.containsDateLiteral(preview)) {
                total += 0.45
            }
            if intents.contains(.asksDate),
               RerankingHelpers.containsTentativeLaunchLanguage(previewLower) {
                let basePenalty = config.answerDistractorPenalty
                total -= vectorInfluenced ? basePenalty * 2.8 : basePenalty * 1.8
            }
            if intents.contains(.asksOwnership),
               (previewLower.contains("owns deployment readiness") || previewLower.contains(" owns ")) {
                total += 0.45
            }
            if looksDistractor(previewLower) {
                let basePenalty = config.answerDistractorPenalty
                total -= vectorInfluenced ? basePenalty * 2.2 : basePenalty
                if vectorInfluenced, intents.contains(.asksDate), !analyzer.containsDateLiteral(preview) {
                    total -= 0.35
                }
            }
            return total
        }

        var head = Array(results.prefix(cappedWindow))
        head.sort { lhs, rhs in
            let lhsKey = sortKey(lhs)
            let rhsKey = sortKey(rhs)
            if lhsKey != rhsKey { return lhsKey > rhsKey }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameId < rhs.frameId
        }

        if cappedWindow == results.count { return head }
        return head + results.dropFirst(cappedWindow)
    }

    /// FastRAG distractor check — narrower than UnifiedSearch.looksDistractorLike.
    /// Includes "no authoritative" (confidence-undermining language) which UnifiedSearch omits.
    /// Omits "allergic", "draft memo", "tentative", "pending approval" which are already
    /// handled by dedicated intent-specific penalties in the FastRAG scoring path.
    private static func looksDistractor(_ text: String) -> Bool {
        text.contains("no authoritative")
            || text.contains("weekly report")
            || text.contains("checklist")
            || text.contains("signoff")
            || text.contains("distractor")
    }

    // containsTentativeLaunchLanguage → RerankingHelpers (shared with UnifiedSearch)
    // containsDateLiteral → use analyzer.containsDateLiteral() directly (avoids throwaway QueryAnalyzer)

    private func expansionText(
        frameId: UInt64,
        wax: Wax,
        maxBytes: Int
    ) async throws -> String? {
        guard maxBytes > 0 else { return nil }

        // Fetch meta and payload sequentially to avoid Swift 6 async let actor isolation double-free crash.
        let meta = try await wax.frameMetaIncludingPending(frameId: frameId)
        let data = try await wax.frameContentIncludingPending(frameId: frameId)

        let canonicalBytes: UInt64
        if meta.canonicalEncoding == .plain {
            canonicalBytes = meta.payloadLength
        } else if let length = meta.canonicalLength {
            canonicalBytes = length
        } else {
            throw WaxError.invalidToc(reason: "missing canonical_length for frame \(frameId)")
        }
        guard canonicalBytes > 0 else { return nil }
        guard canonicalBytes <= UInt64(maxBytes) else { return nil }

        try Self.validateExpansionPayloadSize(
            expectedBytes: canonicalBytes,
            actualBytes: data.count,
            maxBytes: maxBytes
        )
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func validateExpansionPayloadSize(
        expectedBytes: UInt64,
        actualBytes: Int,
        maxBytes: Int
    ) throws {
        guard maxBytes > 0 else { return }
        if actualBytes > maxBytes {
            throw WaxError.io("expansion payload exceeds cap: \(actualBytes) > \(maxBytes)")
        }
        if actualBytes != Int(expectedBytes) {
            throw WaxError.io("expansion payload length mismatch: expected \(expectedBytes), got \(actualBytes)")
        }
    }
}
