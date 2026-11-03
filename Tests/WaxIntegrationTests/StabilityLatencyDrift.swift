import Foundation

/// Recall-latency drift between the first and last fifth of a stability replay.
///
/// The replay ingests throughout, so the last window searches a store several
/// times larger than the first. Latency that grows with store size or with
/// each replay step shows up as p50/p95 drift.
struct StabilityLatencyDrift: Sendable {
    struct Summary: Codable, Sendable {
        let samples: Int
        let meanMs: Double
        let p50Ms: Double
        let p95Ms: Double
    }

    let firstWindow: Summary
    let lastWindow: Summary
    let p50DriftPercent: Double
    let p95DriftPercent: Double

    init(samplesMs: [Double]) {
        let windowSize = max(10, samplesMs.count / 5)
        firstWindow = Self.summary(Array(samplesMs.prefix(windowSize)))
        lastWindow = Self.summary(Array(samplesMs.suffix(windowSize)))
        p50DriftPercent = Self.percentDrift(from: firstWindow.p50Ms, to: lastWindow.p50Ms)
        p95DriftPercent = Self.percentDrift(from: firstWindow.p95Ms, to: lastWindow.p95Ms)
    }

    static func summary(_ samples: [Double]) -> Summary {
        guard !samples.isEmpty else {
            return Summary(samples: 0, meanMs: 0, p50Ms: 0, p95Ms: 0)
        }
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        return Summary(
            samples: samples.count,
            meanMs: mean,
            p50Ms: percentile(sorted: sorted, p: 0.50),
            p95Ms: percentile(sorted: sorted, p: 0.95)
        )
    }

    static func percentile(sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = min(1, max(0, p)) * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let weight = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * weight
    }

    static func percentDrift(from baseline: Double, to current: Double) -> Double {
        guard baseline > 0 else { return current > 0 ? 100 : 0 }
        return ((current - baseline) / baseline) * 100
    }
}
