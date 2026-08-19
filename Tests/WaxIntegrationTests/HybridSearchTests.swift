import Foundation
import Testing
import Wax

@Test func rrfFactualExclusiveListsPromoteTextRank1() {
    // Exclusive lists: text top absent from vector, vector top absent from text.
    var merged: [(UInt64, Float)] = [(1, 0.02), (1706, 0.019), (2, 0.01)]
    HybridSearch.applyExclusiveTextRank1Floor(
        merged: &merged,
        textFrameIds: [1706, 99],
        vectorFrameIds: [1, 2],
        applyFloor: true
    )
    #expect(merged.map(\.0) == [1706, 1, 2])
}

@Test func rrfSemanticExclusiveListsKeepVectorRank1() {
    var merged: [(UInt64, Float)] = [(1, 0.02), (1706, 0.019), (2, 0.01)]
    HybridSearch.applyExclusiveTextRank1Floor(
        merged: &merged,
        textFrameIds: [1706, 99],
        vectorFrameIds: [1, 2],
        applyFloor: false
    )
    #expect(merged.map(\.0) == [1, 1706, 2])
}

@Test func rrfORFallbackOnlyTextRank1IsNotFlooredEvenWhenFactual() {
    var merged: [(UInt64, Float)] = [(1, 0.02), (1706, 0.019)]
    HybridSearch.applyExclusiveTextRank1Floor(
        merged: &merged,
        textFrameIds: [1706],
        vectorFrameIds: [1],
        applyFloor: true,
        textRank1IsORFallbackOnly: true
    )
    #expect(merged.map(\.0) == [1, 1706])
}

@Test func publishedRRFScoresStayInUnitIntervalAndKeepOrder() {
    var ranked: [(UInt64, Float)] = [
        (1706, 1.0 / 61.0),
        (1, 0.5 / 61.0),
        (2, 0.25 / 61.0),
    ]
    HybridSearch.publishNormalizedRRFScores(&ranked, k: 60, totalWeight: 1)
    #expect(ranked.map(\.0) == [1706, 1, 2])
    #expect(ranked[0].1 == 1.0)
    #expect(abs(ranked[1].1 - 0.5) < 1e-6)
    #expect(abs(ranked[2].1 - 0.25) < 1e-6)
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

        let hits = try await orchestrator.search(query: "7f3a91", mode: .hybrid(), topK: 10)
        let top = try #require(hits.first)
        #expect(
            top.previewText?.contains("7f3a91") == true,
            "hybrid rank-1 was \(top.previewText ?? "<nil>")"
        )
        #expect(top.sources.contains(.text))
        for (previous, next) in zip(hits, hits.dropFirst()) {
            #expect(previous.score >= next.score)
        }

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
