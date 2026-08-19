/// Hybrid search fusion helpers used by UnifiedSearch ranking.
package enum HybridSearch {
    /// Maps raw RRF (`weight / (k + rank)`) onto `0...1` without changing order.
    /// `totalWeight` is the sum of lane weights that contributed to fusion.
    package static func publishNormalizedRRFScores(
        _ ranked: inout [(UInt64, Float)],
        k: Int,
        totalWeight: Float
    ) {
        let maxRRF = max(0, totalWeight) / Float(max(0, k) + 1)
        guard maxRRF > 0 else { return }
        for index in ranked.indices {
            let normalized = ranked[index].1 / maxRRF
            ranked[index].1 = min(1, max(0, normalized))
        }
    }

    /// Factual identifier queries: exclusive text rank-1 cannot lose to an
    /// exclusive vector-only neighbor. Ranking order only; score scale unchanged
    /// except a `nextUp` bump so later score-sorts keep the same order.
    /// Semantic / exploratory callers must pass `applyFloor: false`.
    /// OR-fallback-only text rank-1 is a 1-of-N overlap, not a lexical canary.
    package static func applyExclusiveTextRank1Floor(
        merged: inout [(UInt64, Float)],
        textFrameIds: [UInt64],
        vectorFrameIds: [UInt64],
        applyFloor: Bool,
        textRank1IsORFallbackOnly: Bool = false
    ) {
        guard applyFloor,
              !textRank1IsORFallbackOnly,
              let lift = exclusiveTextRank1FloorIndices(
                  mergedFrameIds: merged.map(\.0),
                  textFrameIds: textFrameIds,
                  vectorFrameIds: vectorFrameIds
              )
        else { return }

        let lifted = (merged[lift.textIndex].0, merged[lift.vectorIndex].1.nextUp)
        merged.remove(at: lift.textIndex)
        merged.insert(lifted, at: lift.vectorIndex)
    }

    /// Location of an exclusive text rank-1 buried under exclusive vector rank-1.
    package static func exclusiveTextRank1FloorIndices(
        mergedFrameIds: [UInt64],
        textFrameIds: [UInt64],
        vectorFrameIds: [UInt64]
    ) -> (textIndex: Int, vectorIndex: Int)? {
        guard let textTop = textFrameIds.first,
              let vectorTop = vectorFrameIds.first,
              !vectorFrameIds.contains(textTop),
              !textFrameIds.contains(vectorTop),
              let textIndex = mergedFrameIds.firstIndex(of: textTop),
              let vectorIndex = mergedFrameIds.firstIndex(of: vectorTop),
              textIndex > vectorIndex
        else { return nil }
        return (textIndex, vectorIndex)
    }
}

