import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

extension Wax {
    func timelineFallbackResults(request: SearchRequest, filter: FrameFilter, nowMs: Int64) async -> [SearchResponse.Result] {
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

    /// One lane ran alone: keep the engine score and attach single-lane
    /// diagnostics for the head of the list.
    static func singleLaneBaseResults(
        _ hits: [(frameId: UInt64, score: Float)],
        source: SearchResponse.Source,
        weight: Float,
        diagnosticsEnabled: Bool,
        diagnosticsTopK: Int
    ) -> [UnifiedSearchBaseResult] {
        hits.enumerated().map { index, hit in
            let diagnostics: SearchResponse.RankingDiagnostics? =
                if diagnosticsEnabled, index < diagnosticsTopK {
                    .init(
                        bestLaneRank: index + 1,
                        laneContributions: [
                            .init(source: source, weight: weight, rank: index + 1, rrfScore: hit.score),
                        ],
                        tieBreakReason: index == 0 ? .topResult : .fusedScore
                    )
                } else {
                    nil
                }
            return UnifiedSearchBaseResult(
                frameId: hit.frameId,
                score: hit.score,
                sources: [source],
                rankingDiagnostics: diagnostics
            )
        }
    }

    static func baseExplanations(
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

    static func scoredAsORFallbackOnly(
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

    static func scoredAsORFallbackOnly(
        _ results: [TextSearchResult],
        tokenCount: Int
    ) -> [TextSearchResult] {
        let scale = orFallbackOnlyScoreScale(tokenCount: tokenCount)
        guard scale < 1 else { return results }
        return results.map { scoredAsORFallbackOnly($0, tokenCount: tokenCount) }
    }

    package static func dehighlightedPreviewText(_ text: String) -> String {
        UnifiedRanking.dehighlightedPreviewText(text)
    }

    static func structuredEntityCandidates(
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

    static func frameIDsAndSet<S: Sequence>(from frameIDs: S) -> ([UInt64], Set<UInt64>)
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
}
