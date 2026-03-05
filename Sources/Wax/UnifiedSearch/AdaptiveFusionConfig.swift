/// Fusion weights for hybrid search.
package struct FusionWeights: Sendable, Equatable {
    package var bm25: Float
    package var vector: Float
    package var temporal: Float

    package init(bm25: Float, vector: Float, temporal: Float = 0) {
        self.bm25 = bm25
        self.vector = vector
        self.temporal = temporal
    }
}

/// Query-adaptive fusion configuration.
package struct AdaptiveFusionConfig: Sendable {
    private var weightsByType: [QueryType: FusionWeights]

    package static let `default` = AdaptiveFusionConfig()

    package init() {
        self.weightsByType = [
            .factual: FusionWeights(bm25: 0.7, vector: 0.3, temporal: 0.0),
            .semantic: FusionWeights(bm25: 0.3, vector: 0.7, temporal: 0.0),
            .temporal: FusionWeights(bm25: 0.25, vector: 0.25, temporal: 0.5),
            .exploratory: FusionWeights(bm25: 0.4, vector: 0.5, temporal: 0.1),
        ]
    }

    package init(weights: [QueryType: FusionWeights]) {
        self.weightsByType = weights
    }

    package func weights(for queryType: QueryType) -> FusionWeights {
        weightsByType[queryType] ?? FusionWeights(bm25: 0.5, vector: 0.5)
    }
}
