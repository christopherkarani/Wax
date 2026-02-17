/// Unified search response.
public struct SearchResponse: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable, CaseIterable {
        case text
        case vector
        case timeline
        case structuredMemory
    }

    public enum RankingTieBreakReason: String, Sendable, Equatable {
        case topResult
        case rerankComposite
        case fusedScore
        case bestLaneRank
        case frameID
    }

    public struct RankingLaneContribution: Sendable, Equatable {
        public var source: Source
        public var weight: Float
        public var rank: Int
        public var rrfScore: Float

        public init(source: Source, weight: Float, rank: Int, rrfScore: Float) {
            self.source = source
            self.weight = weight
            self.rank = rank
            self.rrfScore = rrfScore
        }
    }

    public struct RankingDiagnostics: Sendable, Equatable {
        public var bestLaneRank: Int?
        public var laneContributions: [RankingLaneContribution]
        public var tieBreakReason: RankingTieBreakReason

        public init(
            bestLaneRank: Int?,
            laneContributions: [RankingLaneContribution],
            tieBreakReason: RankingTieBreakReason = .topResult
        ) {
            self.bestLaneRank = bestLaneRank
            self.laneContributions = laneContributions
            self.tieBreakReason = tieBreakReason
        }
    }

    public struct Result: Sendable, Equatable {
        public var frameId: UInt64
        public var score: Float
        public var previewText: String?
        public var sources: [Source]
        public var rankingDiagnostics: RankingDiagnostics?

        public init(
            frameId: UInt64,
            score: Float,
            previewText: String? = nil,
            sources: [Source],
            rankingDiagnostics: RankingDiagnostics? = nil
        ) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
            self.rankingDiagnostics = rankingDiagnostics
        }
    }

    public var results: [Result]

    public init(results: [Result]) {
        self.results = results
    }
}
