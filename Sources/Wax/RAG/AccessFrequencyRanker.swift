import Foundation

/// Bounded access-aware reranking for already-retrieved candidates.
///
/// Access statistics are a weak preference signal. They may break close ties,
/// but they must not erase lexical/vector relevance or make a frame permanently
/// self-reinforcing merely because it was returned in the past.
package enum AccessFrequencyRanker {
    /// Public to package tests so the cap remains an explicit contract.
    package static let maximumAdjustment: Float = 0.20
    package static let minimumAdjustment: Float = -0.12

    private static let frequencyHalfLifeHours: Float = 30 * 24
    private static let recencyHalfLifeHours: Float = 24
    private static let frequencyCenter: Float = 0.30
    private static let adjustmentScale: Float = 0.45
    private static let countSaturation: UInt32 = 32

    /// Re-rank only a bounded candidate window, preserving the original order
    /// as the final tie-breaker. The caller controls whether the feature is
    /// enabled; an empty stats map is therefore a no-op.
    package static func rerank(
        results: [SearchResponse.Result],
        query: String?,
        accessStats: [UInt64: FrameAccessStats],
        nowMs: Int64,
        maxWindow: Int
    ) -> [SearchResponse.Result] {
        let cappedWindow = min(max(0, maxWindow), results.count)
        guard cappedWindow > 0, !accessStats.isEmpty else { return results }

        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoredHead = results.prefix(cappedWindow).enumerated().map { index, result in
            let stats = accessStats[result.frameId]
            let base = MemorySemantics.accessReasons(
                stats: stats,
                metadata: result.metadata,
                nowMs: nowMs
            )
            let exact = isExplicitExactMatch(result: result, query: query)
            // Exact identifier/quoted phrase hits are already protected by the
            // lexical lane. Never let a stale-access penalty undo that guarantee.
            let adjustment = exact ? max(0, base.adjustment) : base.adjustment
            var updated = result
            // Search scores are rank keys rather than probabilities. Preserve
            // the existing score scale and apply access as a bounded offset;
            // the composite ordering below remains stable for ties.
            updated.score = result.score + adjustment

            var explanations = result.explanations
            if !base.reasons.isEmpty {
                explanations.append(contentsOf: base.reasons)
            }
            if exact, let query, !query.isEmpty {
                let exactReason = MatchPlan.rawQuotedPhrases(from: query).isEmpty
                    ? "exact identifier match"
                    : "exact phrase match"
                explanations.append(exactReason)
            }
            updated.explanations = dedupedExplanations(explanations)

            return (
                index: index,
                composite: updated.score,
                baseScore: result.score,
                result: updated
            )
        }

        let rankedHead = scoredHead.sorted { lhs, rhs in
            if lhs.composite != rhs.composite { return lhs.composite > rhs.composite }
            if lhs.baseScore != rhs.baseScore { return lhs.baseScore > rhs.baseScore }
            return lhs.index < rhs.index
        }.map(\.result)

        guard cappedWindow < results.count else { return rankedHead }
        var combined = rankedHead
        combined.reserveCapacity(results.count)
        combined.append(contentsOf: results.dropFirst(cappedWindow))
        return combined
    }

    /// Computes a bounded, decay-aware adjustment from one access record.
    /// Frequency saturates at 32 accesses and decays over 30 days; recency has
    /// a 24-hour half-life. This makes stale low-use frames demotable without
    /// allowing repeated retrievals to grow the score without bound.
    package static func adjustment(
        stats: FrameAccessStats?,
        metadata: [String: String] = [:],
        nowMs: Int64
    ) -> Float {
        MemorySemantics.accessReasons(
            stats: stats,
            metadata: metadata,
            nowMs: nowMs
        ).adjustment
    }

    package static func rawAdjustment(stats: FrameAccessStats?, nowMs: Int64) -> Float {
        guard let stats else { return 0 }
        let hoursSinceAccess = Float(max(0, nowMs - stats.lastAccessMs)) / (1000 * 60 * 60)
        let frequency = min(
            1,
            log(Float(min(stats.accessCount, countSaturation)) + 1)
                / log(Float(countSaturation) + 1)
        )
        let frequencyDecay = exp(-hoursSinceAccess / frequencyHalfLifeHours)
        let recencyDecay = exp(-hoursSinceAccess / recencyHalfLifeHours)
        let engagement = 0.65 * frequency * frequencyDecay + 0.35 * recencyDecay
        let raw = (engagement - frequencyCenter) * adjustmentScale
        return min(maximumAdjustment, max(minimumAdjustment, raw))
    }

    private static func isExplicitExactMatch(result: SearchResponse.Result, query: String?) -> Bool {
        guard let query, !query.isEmpty,
              let preview = result.previewText,
              !preview.isEmpty
        else { return false }

        let haystack = dehighlightedPreviewText(preview).lowercased()
        let phrases = MatchPlan.rawQuotedPhrases(from: query)
        if phrases.contains(where: { haystack.contains($0.lowercased()) }) {
            return true
        }
        return RuleBasedQueryClassifier.isLexicalIdentifierQuery(query)
            && haystack.contains(query.lowercased())
    }

    private static func dedupedExplanations(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(reasons.count)
        for reason in reasons {
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func dehighlightedPreviewText(_ preview: String) -> String {
        preview
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }
}
