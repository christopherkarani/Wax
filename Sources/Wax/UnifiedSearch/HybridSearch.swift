/// Hybrid search fusion algorithms.
package enum HybridSearch {
    /// Reciprocal Rank Fusion (RRF) to combine ranked lists.
    ///
    /// Notes (v1):
    /// - RRF is rank-based (it ignores the raw score scales from BM25 vs vector distance).
    /// - Provide deterministic tie-break rules so outputs are stable.
    package static func rrfFusion(
        textResults: [(UInt64, Float)],
        vectorResults: [(UInt64, Float)],
        k: Int = 60,
        alpha: Float = 0.5
    ) -> [(UInt64, Float)] {
        let clampedAlpha = min(1, max(0, alpha))
        return rrfFusion(
            lists: [
                (weight: clampedAlpha, frameIds: textResults.map(\.0)),
                (weight: 1 - clampedAlpha, frameIds: vectorResults.map(\.0)),
            ],
            k: k
        )
    }

    /// Multi-list weighted RRF (e.g., text + vector + timeline).
    package static func rrfFusion(
        lists: [(weight: Float, frameIds: [UInt64])],
        k: Int = 60
    ) -> [(UInt64, Float)] {
        let kConstant = max(0, k)
        var scores: [UInt64: Float] = [:]
        var bestRank: [UInt64: Int] = [:]

        for list in lists {
            guard list.weight > 0 else { continue }
            for (rank, frameId) in list.frameIds.enumerated() {
                let rrfScore = list.weight / Float(kConstant + rank + 1)
                scores[frameId, default: 0] += rrfScore
                bestRank[frameId] = min(bestRank[frameId] ?? Int.max, rank + 1)
            }
        }

        return scores.map { (frameId: $0.key, score: $0.value) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                let ra = bestRank[a.frameId] ?? Int.max
                let rb = bestRank[b.frameId] ?? Int.max
                if ra != rb { return ra < rb }
                return a.frameId < b.frameId
            }
    }
}

