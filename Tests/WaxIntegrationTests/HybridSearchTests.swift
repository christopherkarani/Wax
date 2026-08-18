import Foundation
import Testing
import Wax

@Test func rrfWithDisjointResults() {
    let textResults: [(UInt64, Float)] = [(0, 0.9), (1, 0.8), (2, 0.7)]
    let vectorResults: [(UInt64, Float)] = [(3, 0.95), (4, 0.85), (5, 0.75)]

    let merged = HybridSearch.rrfFusion(
        textResults: textResults,
        vectorResults: vectorResults,
        k: 60,
        alpha: 0.5
    )

    #expect(merged.count == 6)
    let frameIds = Set(merged.map { $0.0 })
    #expect(frameIds == Set([0, 1, 2, 3, 4, 5]))
}

@Test func rrfWithOverlappingResults() {
    let textResults: [(UInt64, Float)] = [(0, 0.9), (1, 0.8)]
    let vectorResults: [(UInt64, Float)] = [(1, 0.95), (2, 0.85)]

    let merged = HybridSearch.rrfFusion(
        textResults: textResults,
        vectorResults: vectorResults,
        k: 60,
        alpha: 0.5
    )

    #expect(merged.count == 3)
    #expect(merged[0].0 == 1)
}

@Test func rrfAlphaWeighting() {
    let textResults: [(UInt64, Float)] = [(0, 0.9)]
    let vectorResults: [(UInt64, Float)] = [(1, 0.95)]

    let textOnly = HybridSearch.rrfFusion(
        textResults: textResults,
        vectorResults: vectorResults,
        k: 60,
        alpha: 1.0
    )
    #expect(textOnly[0].0 == 0)

    let vectorOnly = HybridSearch.rrfFusion(
        textResults: textResults,
        vectorResults: vectorResults,
        k: 60,
        alpha: 0.0
    )
    #expect(vectorOnly[0].0 == 1)
}

@Test func rrfWithEmptyTextResults() {
    let textResults: [(UInt64, Float)] = []
    let vectorResults: [(UInt64, Float)] = [(0, 0.9), (1, 0.8)]

    let merged = HybridSearch.rrfFusion(
        textResults: textResults,
        vectorResults: vectorResults,
        k: 60,
        alpha: 0.5
    )

    #expect(merged.count == 2)
}

@Test func rrfWithEmptyVectorResults() {
    let textResults: [(UInt64, Float)] = [(0, 0.9), (1, 0.8)]
    let vectorResults: [(UInt64, Float)] = []

    let merged = HybridSearch.rrfFusion(
        textResults: textResults,
        vectorResults: vectorResults,
        k: 60,
        alpha: 0.5
    )

    #expect(merged.count == 2)
}

@Test func rrfExclusiveTextRank1BeatsExclusiveVectorNeighborAtDefaultAlpha() {
    // Vector neighbor gets a lower frame id so the old frame-id tie-break would
    // bury the exclusive lexical canary when RRF scores are equal or vector-leaning.
    let textCanary: UInt64 = 1706
    let vectorNeighbor: UInt64 = 1
    let merged = HybridSearch.rrfFusion(
        textResults: [(textCanary, 0.9)],
        vectorResults: [(vectorNeighbor, 0.95)],
        k: 60,
        alpha: 0.5
    )

    #expect(merged.first?.0 == textCanary)
}

@Test func hybridSearchRanksUniqueLexicalCanaryAboveVectorNeighbors() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 400, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: CanaryConfusionEmbedder()
        )
        try await orchestrator.remember("test with embedder Osaurus telemetry heartbeat")
        try await orchestrator.remember("session health probe MiniLM neighbor filler")
        try await orchestrator.remember("unique lexical canary 7f3a91 stored for hybrid recall")
        try await orchestrator.flush()

        let hits = try await orchestrator.search(query: "7f3a91", mode: .default, topK: 10)
        let top = try #require(hits.first)
        #expect(
            top.previewText?.contains("7f3a91") == true,
            "hybrid rank-1 was \(top.previewText ?? "<nil>")"
        )

        try await orchestrator.close()
    }
}

private struct CanaryConfusionEmbedder: EmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "CanaryConfusion",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let lowered = text.lowercased()
        if lowered.contains("7f3a91"), lowered != "7f3a91" {
            return VectorMath.normalizeL2([0, 1])
        }
        return VectorMath.normalizeL2([1, 0])
    }
}

