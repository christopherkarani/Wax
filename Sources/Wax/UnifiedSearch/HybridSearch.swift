/// Hybrid search fusion helpers used by UnifiedSearch ranking.
package enum HybridSearch {
    /// One fused candidate after Reciprocal Rank Fusion.
    package struct FusionResult: Sendable, Equatable {
        package var frameId: UInt64
        package var score: Float
        package var sources: [SearchResponse.Source]
        package var diagnostics: SearchResponse.RankingDiagnostics?
    }

    /// Reciprocal Rank Fusion across weighted lane id lists.
    /// Sort: fused score desc, best lane rank asc, frameId asc.
    package static func rrfFusionResults(
        lists: [(source: SearchResponse.Source, weight: Float, frameIds: [UInt64])],
        k: Int,
        includeDiagnostics: Bool,
        diagnosticsTopK: Int
    ) -> [FusionResult] {
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
        var fused: [FusionResult] = []
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
                FusionResult(
                    frameId: candidate.frameId,
                    score: candidate.score,
                    sources: candidate.sources,
                    diagnostics: diagnostics
                )
            )
        }
        return fused
    }

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

    private struct RRFFusedCandidate {
        let frameId: UInt64
        let score: Float
        let bestRank: Int
        let sources: [SearchResponse.Source]
        let laneContributions: [SearchResponse.RankingLaneContribution]
    }
}
