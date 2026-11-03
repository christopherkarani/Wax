import Foundation
import Testing

/// The burn/soak gates compare recall latency in the first and last fifth of a
/// replay. These cases pin that the comparison flags latency that grows with
/// each replay step and tolerates a flat, noisy run with a cold first sample.
struct StabilityLatencyDriftTests {
    private static let sampleCount = 450
    private static let burnP50BudgetPct = 200.0
    private static let burnP95BudgetPct = 260.0

    /// Flat ~0.9 ms latencies with deterministic jitter, a cold first recall and
    /// a periodic engine reload (every eighth recall follows a commit).
    private static func flatNoisyRun() -> [Double] {
        var state: UInt64 = 20_261_103
        return (0..<sampleCount).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let jitter = Double(state >> 40) / Double(1 << 24) * 0.3
            if index == 0 { return 4.0 }
            return 0.9 + jitter + (index % 8 == 0 ? 1.5 : 0)
        }
    }

    @Test func flatNoisyRunStaysWithinBurnBudgets() {
        let drift = StabilityLatencyDrift(samplesMs: Self.flatNoisyRun())

        #expect(drift.firstWindow.samples == 90)
        #expect(drift.lastWindow.samples == 90)
        #expect(drift.p50DriftPercent < 50)
        #expect(drift.p95DriftPercent < 50)
        #expect(drift.p50DriftPercent <= Self.burnP50BudgetPct)
        #expect(drift.p95DriftPercent <= Self.burnP95BudgetPct)
    }

    /// Latency that grows by a fixed amount per recall, as an O(store size)
    /// search does, must exceed the burn budget.
    @Test func perIterationSlowdownExceedsBurnBudget() {
        let slowdownMsPerRecall = 0.02
        let slowed = Self.flatNoisyRun().enumerated().map { index, latency in
            latency + Double(index) * slowdownMsPerRecall
        }

        let drift = StabilityLatencyDrift(samplesMs: slowed)

        #expect(drift.p50DriftPercent > Self.burnP50BudgetPct)
    }

    @Test func zeroBaselineReportsFullDriftOnlyWhenLatencyAppears() {
        #expect(StabilityLatencyDrift.percentDrift(from: 0, to: 0) == 0)
        #expect(StabilityLatencyDrift.percentDrift(from: 0, to: 1) == 100)
        #expect(StabilityLatencyDrift.percentDrift(from: 2, to: 3) == 50)
    }
}
