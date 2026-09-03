import Testing
@testable import Wax

struct HybridFusionTests {
    @Test
    func singleLaneOrdersByRankAndPinsTopKDiagnostics() throws {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0.7, frameIds: [2, 1]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        try #require(fused.count == 2)
        #expect(fused.map(\.frameId) == [2, 1])
        #expect(fused[0].score == Float(0.7) / 61)
        #expect(fused[1].score == Float(0.7) / 62)
        #expect(fused[0].sources == [.text])
        #expect(fused[1].sources == [.text])
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[0].diagnostics?.bestLaneRank == 1)
        #expect(fused[1].diagnostics?.tieBreakReason == .fusedScore)
        #expect(fused[1].diagnostics?.bestLaneRank == 2)
        let topContributions = try #require(fused[0].diagnostics?.laneContributions)
        try #require(topContributions.count == 1)
        #expect(topContributions[0].source == .text)
        #expect(topContributions[0].weight == 0.7)
        #expect(topContributions[0].rank == 1)
        #expect(topContributions[0].rrfScore == Float(0.7) / 61)
    }

    @Test
    func twoExclusiveLanesFuseByReciprocalRank() throws {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0.7, frameIds: [2, 1]),
                (source: .vector, weight: 0.3, frameIds: [1, 3]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        try #require(fused.count == 3)
        #expect(fused.map(\.frameId) == [1, 2, 3])
        #expect(fused[0].score == (Float(0.7) / 62) + (Float(0.3) / 61))
        #expect(fused[1].score == Float(0.7) / 61)
        #expect(fused[2].score == Float(0.3) / 62)
        #expect(fused[0].sources == [.text, .vector])
        #expect(fused[1].sources == [.text])
        #expect(fused[2].sources == [.vector])
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics?.tieBreakReason == .fusedScore)
        #expect(fused[2].diagnostics?.tieBreakReason == .fusedScore)
        #expect(fused[0].diagnostics?.bestLaneRank == 1)
        #expect(fused[1].diagnostics?.bestLaneRank == 1)
        #expect(fused[2].diagnostics?.bestLaneRank == 2)

        let overlap = try #require(fused[0].diagnostics?.laneContributions)
        try #require(overlap.count == 2)
        #expect(overlap.map(\.source) == [.text, .vector])
        #expect(overlap[0].rank == 2)
        #expect(overlap[0].rrfScore == Float(0.7) / 62)
        #expect(overlap[1].rank == 1)
        #expect(overlap[1].rrfScore == Float(0.3) / 61)
    }

    @Test
    func equalFusedScoreBreaksTiesByBestLaneRank() throws {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 2, frameIds: [100, 10]),
                (source: .vector, weight: 1, frameIds: [20]),
            ],
            k: 0,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        try #require(fused.count == 3)
        #expect(fused.map(\.frameId) == [100, 20, 10])
        #expect(fused[0].score == 2)
        #expect(fused[1].score == 1)
        #expect(fused[2].score == 1)
        #expect(fused[1].score == fused[2].score)
        #expect(fused[1].diagnostics?.bestLaneRank == 1)
        #expect(fused[2].diagnostics?.bestLaneRank == 2)
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics?.tieBreakReason == .fusedScore)
        #expect(fused[2].diagnostics?.tieBreakReason == .bestLaneRank)
    }

    @Test
    func remainingTieBreaksByFrameId() throws {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 1, frameIds: [9]),
                (source: .vector, weight: 1, frameIds: [4]),
                (source: .structured, weight: 1, frameIds: [7]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        try #require(fused.count == 3)
        #expect(fused.map(\.frameId) == [4, 7, 9])
        #expect(fused[0].score == fused[1].score)
        #expect(fused[1].score == fused[2].score)
        #expect(fused[0].diagnostics?.bestLaneRank == 1)
        #expect(fused[1].diagnostics?.bestLaneRank == 1)
        #expect(fused[2].diagnostics?.bestLaneRank == 1)
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics?.tieBreakReason == .frameID)
        #expect(fused[2].diagnostics?.tieBreakReason == .frameID)
    }

    @Test
    func diagnosticsAttachOnlyToTopK() throws {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0.7, frameIds: [2, 1]),
                (source: .vector, weight: 0.3, frameIds: [1, 3]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 1
        )

        try #require(fused.count == 3)
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics == nil)
        #expect(fused[2].diagnostics == nil)
    }

    @Test
    func zeroWeightLaneIsIgnoredAndDiagnosticsCanBeOmitted() throws {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0, frameIds: [2, 1]),
                (source: .vector, weight: 0.3, frameIds: [3]),
            ],
            k: 60,
            includeDiagnostics: false,
            diagnosticsTopK: 10
        )

        try #require(fused.count == 1)
        #expect(fused[0].frameId == 3)
        #expect(fused[0].score == Float(0.3) / 61)
        #expect(fused[0].sources == [.vector])
        #expect(fused[0].diagnostics == nil)
    }
}
