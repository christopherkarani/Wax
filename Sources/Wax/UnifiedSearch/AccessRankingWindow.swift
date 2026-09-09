import Foundation
import WaxCore

/// Shared overfetch window for access-aware reranking.
///
/// Search and FastRAG keep different multipliers/caps; this helper encodes
/// the shared rule without silently unifying those numbers.
package enum AccessRankingWindow {
    /// Candidate count for the retrieval stage when access ranking may run.
    ///
    /// - Parameters:
    ///   - requestedTopK: Caller-facing result count.
    ///   - accessEnabled: Whether access-stat reranking is on for this call.
    ///   - multiplier: Overfetch factor (`3` search, `2` FastRAG).
    ///   - applyWhenRequestedTopKAtMost: Cap at/under which overfetch applies
    ///     (`16` search, `24` FastRAG). Above the cap, returns `requestedTopK`.
    package static func candidateCount(
        requestedTopK: Int,
        accessEnabled: Bool,
        multiplier: Int,
        applyWhenRequestedTopKAtMost: Int
    ) -> Int {
        guard accessEnabled, requestedTopK <= applyWhenRequestedTopKAtMost else {
            return requestedTopK
        }
        return SearchPlan.boundedMultiply(requestedTopK, by: multiplier)
    }
}

/// Shared access-stat rerank seam for `searchExecution` and FastRAG.
package enum RankedSearch {
    package static func applyAccessRanking(
        results: [SearchResponse.Result],
        query: String,
        accessStats: [UInt64: FrameAccessStats],
        nowMs: Int64,
        maxWindow: Int,
        enabled: Bool
    ) -> [SearchResponse.Result] {
        guard enabled else { return results }
        return AccessFrequencyRanker.rerank(
            results: results,
            query: query,
            accessStats: accessStats,
            nowMs: nowMs,
            maxWindow: maxWindow
        )
    }
}
