import Testing
@testable import Wax

struct HybridFusionTests {
    @Test
    func singleLaneOrdersByRankAndPinsTopKDiagnostics() {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0.7, frameIds: [2, 1]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        #expect(fused.map(\.frameId) == [2, 1])
        #expect(fused[0].score == Float(0.7) / 61)
        #expect(fused[1].score == Float(0.7) / 62)
        #expect(fused[0].sources == [.text])
        #expect(fused[1].sources == [.text])
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[0].diagnostics?.bestLaneRank == 1)
        #expect(fused[1].diagnostics?.tieBreakReason == .fusedScore)
        #expect(fused[1].diagnostics?.bestLaneRank == 2)
    }

    @Test
    func twoExclusiveLanesFuseByReciprocalRank() {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0.7, frameIds: [2, 1]),
                (source: .vector, weight: 0.3, frameIds: [1, 3]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

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
    }

    @Test
    func equalFusedScoreBreaksTiesByBestLaneRank() {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 2, frameIds: [100, 10]),
                (source: .vector, weight: 1, frameIds: [20]),
            ],
            k: 0,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        #expect(fused.map(\.frameId) == [100, 20, 10])
        #expect(fused[1].score == fused[2].score)
        #expect(fused[1].diagnostics?.bestLaneRank == 1)
        #expect(fused[2].diagnostics?.bestLaneRank == 2)
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics?.tieBreakReason == .fusedScore)
        #expect(fused[2].diagnostics?.tieBreakReason == .bestLaneRank)
    }

    @Test
    func remainingTieBreaksByFrameId() {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 1, frameIds: [5]),
                (source: .vector, weight: 1, frameIds: [3]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 10
        )

        #expect(fused.map(\.frameId) == [3, 5])
        #expect(fused[0].score == fused[1].score)
        #expect(fused[0].diagnostics?.bestLaneRank == 1)
        #expect(fused[1].diagnostics?.bestLaneRank == 1)
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics?.tieBreakReason == .frameID)
    }

    @Test
    func diagnosticsAttachOnlyToTopK() {
        let fused = HybridSearch.rrfFusionResults(
            lists: [
                (source: .text, weight: 0.7, frameIds: [2, 1]),
                (source: .vector, weight: 0.3, frameIds: [1, 3]),
            ],
            k: 60,
            includeDiagnostics: true,
            diagnosticsTopK: 1
        )

        #expect(fused.count == 3)
        #expect(fused[0].diagnostics?.tieBreakReason == .topResult)
        #expect(fused[1].diagnostics == nil)
        #expect(fused[2].diagnostics == nil)
    }
}
