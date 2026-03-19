/// Unified search response.
package struct SearchResponse: Sendable, Equatable {
    package enum Source: String, Sendable, Equatable, CaseIterable {
        case text
        case vector
        case timeline
        case structuredMemory
    }

    package enum RankingTieBreakReason: String, Sendable, Equatable {
        case topResult
        case rerankComposite
        case fusedScore
        case bestLaneRank
        case frameID
    }

    package struct RankingLaneContribution: Sendable, Equatable {
        package var source: Source
        package var weight: Float
        package var rank: Int
        package var rrfScore: Float

        package init(source: Source, weight: Float, rank: Int, rrfScore: Float) {
            self.source = source
            self.weight = weight
            self.rank = rank
            self.rrfScore = rrfScore
        }
    }

    package struct RankingDiagnostics: Sendable, Equatable {
        package var bestLaneRank: Int?
        package var laneContributions: [RankingLaneContribution]
        package var tieBreakReason: RankingTieBreakReason

        package init(
            bestLaneRank: Int?,
            laneContributions: [RankingLaneContribution],
            tieBreakReason: RankingTieBreakReason = .topResult
        ) {
            self.bestLaneRank = bestLaneRank
            self.laneContributions = laneContributions
            self.tieBreakReason = tieBreakReason
        }
    }

    package struct Result: Sendable, Equatable {
        package var frameId: UInt64
        package var score: Float
        package var previewText: String?
        package var sources: [Source]
        package var rankingDiagnostics: RankingDiagnostics?
        package var metadata: [String: String]

        package init(
            frameId: UInt64,
            score: Float,
            previewText: String? = nil,
            sources: [Source],
            rankingDiagnostics: RankingDiagnostics? = nil,
            metadata: [String: String] = [:]
        ) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
            self.rankingDiagnostics = rankingDiagnostics
            self.metadata = metadata
        }
    }

    package var results: [Result]

    package init(results: [Result]) {
        self.results = results
    }
}
