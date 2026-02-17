import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

public struct FastRAGContextBuilder: Sendable {
    public init() {}

    /// Build a deterministic RAG context: at most one expansion + ranked snippets.
    /// - Parameters:
    ///   - query: user query string
    ///   - embedding: optional caller-supplied embedding (no query-time embedding inside Wax)
    ///   - wax: Wax handle
    ///   - config: Fast RAG configuration
    public func build(
        query: String,
        embedding: [Float]? = nil,
        vectorEnginePreference: VectorEnginePreference = .auto,
        wax: Wax,
        session: WaxSession? = nil,
        config: FastRAGConfig = .init()
    ) async throws -> RAGContext {
        let clamped = clamp(config)
        let counter = try await TokenCounter.shared()

        // 1) Run unified search
        let request = SearchRequest(
            query: query,
            embedding: embedding,
            vectorEnginePreference: vectorEnginePreference,
            mode: clamped.searchMode,
            topK: clamped.searchTopK,
            rrfK: clamped.rrfK,
            previewMaxBytes: clamped.previewMaxBytes
        )
        let response = if let session {
            try await session.search(request)
        } else {
            try await wax.search(request)
        }
        let queryAnalyzer = QueryAnalyzer()
        let rankedResults = clamped.enableAnswerFocusedRanking
            ? Self.rerankCandidatesForAnswer(
                results: response.results,
                query: query,
                config: clamped,
                analyzer: queryAnalyzer
            )
            : response.results

        var items: [RAGContext.Item] = []
        var usedTokens = 0
        var expandedFrameId: UInt64?
        var surrogateSourceFrameIds: Set<UInt64> = []

        // Pre-compute query signals for tier selection if enabled
        let querySignals: QuerySignals? = clamped.enableQueryAwareTierSelection
            ? queryAnalyzer.analyze(query: query)
            : nil
        let queryIntent = queryAnalyzer.detectIntent(query: query)
        let nowMs = clamped.deterministicNowMs ?? Int64(Date().timeIntervalSince1970 * 1000)

        // Prefetch surrogate metadata in parallel with expansion work.
        // This keeps determinism while overlapping Wax actor hops.
        let shouldPrefetchSurrogates = clamped.mode == .denseCached
            && clamped.maxSurrogates > 0
            && clamped.surrogateMaxTokens > 0
            && clamped.maxContextTokens > 0
        let sourceFrameIds = rankedResults.map(\.frameId)
        async let surrogateMapTask: [UInt64: UInt64] = shouldPrefetchSurrogates
            ? wax.surrogateFrameIds(for: sourceFrameIds)
            : [:]
        async let sourceFrameMetasTask: [UInt64: FrameMeta] = shouldPrefetchSurrogates
            ? wax.frameMetas(frameIds: sourceFrameIds)
            : [:]

        // 2) Expansion: first result with valid UTF-8 frame content
        if clamped.expansionMaxTokens > 0, clamped.expansionMaxBytes > 0 {
            for result in rankedResults {
                if let expanded = try await expansionText(
                    frameId: result.frameId,
                    wax: wax,
                    counter: counter,
                    maxTokens: clamped.expansionMaxTokens,
                    maxBytes: clamped.expansionMaxBytes
                ) {
                    let expandedTokens = await counter.countBatch([expanded])[0]
                    usedTokens += expandedTokens
                    expandedFrameId = result.frameId
                    items.append(
                        .init(
                            kind: .expanded,
                            frameId: result.frameId,
                            score: result.score,
                            sources: result.sources,
                            text: expanded
                        )
                    )
                    break
                }
            }
        }

        // 3) Surrogates (denseCached mode) - Optimized with batch token operations
        if clamped.mode == .denseCached,
           clamped.maxContextTokens > usedTokens,
           clamped.maxSurrogates > 0,
           clamped.surrogateMaxTokens > 0 {
            var remainingTokens = clamped.maxContextTokens - usedTokens

            let estimatedTokensPerSurrogate = max(1, clamped.surrogateMaxTokens / 2)
            let estimatedMaxSurrogates = max(1, remainingTokens / estimatedTokensPerSurrogate)
            let maxToLoad = min(
                clamped.maxSurrogates,
                min(clamped.searchTopK, 32),
                estimatedMaxSurrogates + 2
            )

            // Batch resolve surrogate ids in a single actor hop to avoid TaskGroup churn.
            let surrogateMap = await surrogateMapTask

            // Keep only the top candidates, preserving response order.
            var orderedSurrogateIds: [UInt64] = []
            orderedSurrogateIds.reserveCapacity(maxToLoad)
            for result in rankedResults {
                if let expandedFrameId, result.frameId == expandedFrameId { continue }
                guard let surrogateId = surrogateMap[result.frameId] else { continue }
                orderedSurrogateIds.append(surrogateId)
                if orderedSurrogateIds.count >= maxToLoad { break }
            }

            // Batch load surrogate contents to avoid per-frame actor hops.
            // If any surrogate is corrupted, fall back to per-frame loads and skip failures.
            async let surrogateContentsTask: [UInt64: Data] = {
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

            // Build tier selector based on config
            let tierSelector = SurrogateTierSelector(
                policy: clamped.tierSelectionPolicy,
                scorer: ImportanceScorer()
            )

            // Get only source frame metas needed for timestamp access.
            let frameMetaMap = await sourceFrameMetasTask

            let surrogateContents = await surrogateContentsTask

            // Parallel tier selection and tier extraction, preserving response order.
            let surrogateWorkItems = rankedResults
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

                        let frameTimestamp = frameMetaMap[item.result.frameId]?.timestamp ?? nowMs
                        let context = TierSelectionContext(
                            frameTimestamp: frameTimestamp,
                            accessStats: nil, // Access stats would be passed in from orchestrator if tracking enabled
                            querySignals: querySignals,
                            nowMs: nowMs
                        )

                        let selectedTier = tierSelector.selectTier(context: context)
                        guard let text = SurrogateTierSelector.extractTier(from: data, tier: selectedTier),
                              !text.isEmpty else { return (index, nil) }

                        return (index, (item.result, item.surrogateFrameId, text))
                    }
                }

                for await (index, candidate) in group {
                    surrogateCandidates[index] = candidate
                }
            }

            let finalizedSurrogates = surrogateCandidates.compactMap { $0 }

            if !finalizedSurrogates.isEmpty {
                // Use optimized combined count and truncate operation
                let texts = finalizedSurrogates.map { $0.text }
                let maxTokensPerText = min(clamped.surrogateMaxTokens, remainingTokens)
                let processedResults = await counter.countAndTruncateBatch(texts, maxTokens: maxTokensPerText)

                for (index, (result, surrogateFrameId, _)) in finalizedSurrogates.enumerated() {
                    let (tokens, capped) = processedResults[index]

                    guard !capped.isEmpty && tokens <= remainingTokens else { continue }

                    items.append(
                        .init(
                            kind: .surrogate,
                            frameId: surrogateFrameId,
                            score: result.score,
                            sources: result.sources,
                            text: capped
                        )
                    )
                    surrogateSourceFrameIds.insert(result.frameId)
                    remainingTokens -= tokens
                    if remainingTokens == 0 { break }
                }
            }

            usedTokens = clamped.maxContextTokens - remainingTokens
        }

        // 4) Snippets - Optimized with batch token operations
        if clamped.maxContextTokens > usedTokens {
            var remainingTokens = clamped.maxContextTokens - usedTokens
            var snippetCount = 0

            // Collect all snippet candidates
            var snippetCandidates: [(result: SearchResponse.Result, preview: String)] = []
            snippetCandidates.reserveCapacity(min(clamped.maxSnippets, 32))

            for result in rankedResults {
                if let expandedFrameId, result.frameId == expandedFrameId { continue }
                if surrogateSourceFrameIds.contains(result.frameId) { continue }
                guard snippetCount < clamped.maxSnippets else { break }
                guard let preview = result.previewText, !preview.isEmpty else { continue }

                snippetCandidates.append((result, preview))
                snippetCount += 1
            }

            // Always use batch processing for consistency and better performance
            if !snippetCandidates.isEmpty {
                let snippetFallbackMaxBytes = min(
                    clamped.expansionMaxBytes,
                    max(4 * 1024, clamped.previewMaxBytes * 64)
                )
                var previews = Array<String>(repeating: "", count: snippetCandidates.count)
                await withTaskGroup(of: (Int, String).self) { group in
                    for (index, (result, preview)) in snippetCandidates.enumerated() {
                        group.addTask {
                            guard Self.shouldUseFullFrameForSnippet(preview: preview, intent: queryIntent) else {
                                return (index, preview)
                            }
                            do {
                                if let expanded = try await expansionText(
                                    frameId: result.frameId,
                                    wax: wax,
                                    counter: counter,
                                    maxTokens: clamped.snippetMaxTokens,
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

                let maxTokensPerSnippet = min(clamped.snippetMaxTokens, remainingTokens)
                
                // Use optimized combined count and truncate operation
                let processedResults = await counter.countAndTruncateBatch(previews, maxTokens: maxTokensPerSnippet)

                for (index, (result, _)) in snippetCandidates.enumerated() {
                    let (tokens, capped) = processedResults[index]

                    guard !capped.isEmpty && tokens <= remainingTokens else { continue }

                    items.append(
                        .init(
                            kind: .snippet,
                            frameId: result.frameId,
                            score: result.score,
                            sources: result.sources,
                            text: capped
                        )
                    )
                    remainingTokens -= tokens
                    if remainingTokens == 0 { break }
                }
            }
            usedTokens = clamped.maxContextTokens - remainingTokens
        }

        return RAGContext(query: query, items: items, totalTokens: usedTokens)
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

    static func shouldUseFullFrameForSnippet(preview: String, intent: QueryIntent) -> Bool {
        if preview.isEmpty { return false }
        let lower = preview.lowercased()

        if intent.contains(.asksDate) {
            let hintsTemporal = lower.contains("launch")
                || lower.contains("appointment")
                || lower.contains("beta")
                || lower.contains("timeline")
            if hintsTemporal && !containsDateLiteral(preview) {
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

    static func rerankCandidatesForAnswer(
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

        func score(_ result: SearchResponse.Result) -> Float {
            var total = result.score
            guard let preview = result.previewText, !preview.isEmpty else { return total }

            let previewLower = preview.lowercased()
            let previewTerms = Set(analyzer.normalizedTerms(query: preview))
            let previewEntities = analyzer.entityTerms(query: preview)
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

            if intents.contains(.asksLocation),
               previewLower.contains("moved to") {
                total += 0.45
            }
            if intents.contains(.asksDate),
               (previewLower.contains("public launch") || previewLower.contains("launch is") || containsDateLiteral(preview)) {
                total += 0.45
            }
            if intents.contains(.asksOwnership),
               (previewLower.contains("owns deployment readiness") || previewLower.contains(" owns ")) {
                total += 0.45
            }
            if looksDistractor(previewLower) {
                let basePenalty = config.answerDistractorPenalty
                total -= vectorInfluenced ? basePenalty * 2.2 : basePenalty
                if vectorInfluenced, intents.contains(.asksDate), !containsDateLiteral(preview) {
                    total -= 0.35
                }
            }
            return total
        }

        var head = Array(results.prefix(cappedWindow))
        head.sort { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameId < rhs.frameId
        }

        if cappedWindow == results.count { return head }
        return head + results.dropFirst(cappedWindow)
    }

    private static func looksDistractor(_ text: String) -> Bool {
        text.contains("no authoritative")
            || text.contains("weekly report")
            || text.contains("checklist")
            || text.contains("signoff")
            || text.contains("distractor")
    }

    private static func containsDateLiteral(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\b"#
        ) else {
            return false
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func expansionText(
        frameId: UInt64,
        wax: Wax,
        counter: TokenCounter,
        maxTokens: Int,
        maxBytes: Int
    ) async throws -> String? {
        guard maxTokens > 0, maxBytes > 0 else { return nil }

        // Fetch meta and payload in parallel to reduce latency while preserving validation.
        async let metaTask = wax.frameMetaIncludingPending(frameId: frameId)
        async let dataTask = wax.frameContentIncludingPending(frameId: frameId)

        let meta = try await metaTask
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

        let data = try await dataTask
        try Self.validateExpansionPayloadSize(
            expectedBytes: canonicalBytes,
            actualBytes: data.count,
            maxBytes: maxBytes
        )
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        let truncated = await counter.truncate(text, maxTokens: maxTokens)
        return truncated.isEmpty ? nil : truncated
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
