#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import Wax

final class ProductionReadinessStabilityTests: XCTestCase {
    private enum Profile: String {
        case soakSmoke = "soak-smoke"
        case burnSmoke = "burn-smoke"
    }

    private struct LatencySummary: Codable, Sendable {
        let samples: Int
        let meanMs: Double
        let p50Ms: Double
        let p95Ms: Double
    }

    private struct StabilityReport: Codable, Sendable {
        let profile: String
        let replaySeed: UInt64
        let replaySteps: Int
        let recallSamples: Int
        let startRSSBytes: UInt64
        let endRSSBytes: UInt64
        let rssGrowthBytes: UInt64
        let firstWindow: LatencySummary
        let lastWindow: LatencySummary
        let p50DriftPercent: Double
        let p95DriftPercent: Double
    }

    func testSoakSmokeStability() async throws {
        try await runStabilityProfile(.soakSmoke)
    }

    func testBurnSmokeStability() async throws {
        try await runStabilityProfile(.burnSmoke)
    }

    private func runStabilityProfile(_ profile: Profile) async throws {
        let env = ProcessInfo.processInfo.environment
        let defaultIterations = (profile == .burnSmoke) ? 1_200 : 500
        let defaultSeed: UInt64 = (profile == .burnSmoke) ? 2_026_021_801 : 2_026_021_800
        let commitBatch = max(1, env["WAX_STABILITY_COMMIT_BATCH"].flatMap(Int.init) ?? 32)

        let plan = try DeterministicReplaySupport.loadOrGeneratePlan(
            name: profile.rawValue,
            defaultSeed: defaultSeed,
            defaultIterations: defaultIterations
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let startRSS = currentRSSBytes()
        let clock = ContinuousClock()

        var recallLatenciesMs: [Double] = []
        recallLatenciesMs.reserveCapacity(plan.steps.count / 4)

        var ingestCount = 0
        var pendingSinceCommit = 0

        for step in plan.steps {
            switch step.action {
            case .ingest:
                let frameID = try await wax.put(
                    Data(step.payload.utf8),
                    options: FrameMetaSubset(searchText: step.payload)
                )
                try await text.index(frameId: frameID, text: step.payload)
                ingestCount += 1
                pendingSinceCommit += 1
                if pendingSinceCommit >= commitBatch {
                    try await text.stageForCommit()
                    try await wax.commit()
                    pendingSinceCommit = 0
                }
            case .recall:
                guard ingestCount > 0 else { continue }
                let start = clock.now
                _ = try await wax.search(
                    SearchRequest(
                        query: step.payload,
                        mode: .textOnly,
                        topK: 8
                    )
                )
                let elapsed = clock.now - start
                recallLatenciesMs.append(Self.durationMs(elapsed))
            }
        }

        if pendingSinceCommit > 0 {
            try await text.stageForCommit()
            try await wax.commit()
        }

        let endRSS = currentRSSBytes()
        try await wax.close()

        XCTAssertGreaterThanOrEqual(recallLatenciesMs.count, 20, "Need enough recall samples to measure drift")
        let windowSize = max(10, recallLatenciesMs.count / 5)
        let firstWindowSamples = Array(recallLatenciesMs.prefix(windowSize))
        let lastWindowSamples = Array(recallLatenciesMs.suffix(windowSize))
        let firstSummary = Self.summary(firstWindowSamples)
        let lastSummary = Self.summary(lastWindowSamples)

        let p50DriftPercent = Self.percentDrift(from: firstSummary.p50Ms, to: lastSummary.p50Ms)
        let p95DriftPercent = Self.percentDrift(from: firstSummary.p95Ms, to: lastSummary.p95Ms)
        let rssGrowthBytes = endRSS >= startRSS ? (endRSS - startRSS) : 0

        let maxRSSGrowthMB = env["WAX_STABILITY_MAX_RSS_GROWTH_MB"].flatMap(UInt64.init)
            ?? ((profile == .burnSmoke) ? 512 : 256)
        let maxP50DriftPct = env["WAX_STABILITY_MAX_P50_DRIFT_PCT"].flatMap(Double.init)
            ?? ((profile == .burnSmoke) ? 200 : 140)
        let maxP95DriftPct = env["WAX_STABILITY_MAX_P95_DRIFT_PCT"].flatMap(Double.init)
            ?? ((profile == .burnSmoke) ? 260 : 180)

        XCTAssertLessThanOrEqual(
            rssGrowthBytes,
            maxRSSGrowthMB * 1_048_576,
            "RSS growth exceeded budget: \(rssGrowthBytes) bytes"
        )
        XCTAssertLessThanOrEqual(
            p50DriftPercent,
            maxP50DriftPct,
            "p50 latency drift exceeded budget: \(String(format: "%.2f", p50DriftPercent))%"
        )
        XCTAssertLessThanOrEqual(
            p95DriftPercent,
            maxP95DriftPct,
            "p95 latency drift exceeded budget: \(String(format: "%.2f", p95DriftPercent))%"
        )

        let report = StabilityReport(
            profile: profile.rawValue,
            replaySeed: plan.seed,
            replaySteps: plan.steps.count,
            recallSamples: recallLatenciesMs.count,
            startRSSBytes: startRSS,
            endRSSBytes: endRSS,
            rssGrowthBytes: rssGrowthBytes,
            firstWindow: firstSummary,
            lastWindow: lastSummary,
            p50DriftPercent: p50DriftPercent,
            p95DriftPercent: p95DriftPercent
        )
        print(
            """
            🧪 Stability \(profile.rawValue): samples=\(report.recallSamples) \
            rss_growth_mb=\(String(format: "%.2f", Double(rssGrowthBytes) / 1_048_576.0)) \
            p50_drift=\(String(format: "%.2f", p50DriftPercent))% \
            p95_drift=\(String(format: "%.2f", p95DriftPercent))%
            """
        )

        if let outputPath = env["WAX_STABILITY_OUTPUT"], !outputPath.isEmpty {
            let url = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        }
    }

    private static func summary(_ samples: [Double]) -> LatencySummary {
        guard !samples.isEmpty else {
            return LatencySummary(samples: 0, meanMs: 0, p50Ms: 0, p95Ms: 0)
        }

        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        return LatencySummary(
            samples: samples.count,
            meanMs: mean,
            p50Ms: percentile(sorted: sorted, p: 0.50),
            p95Ms: percentile(sorted: sorted, p: 0.95)
        )
    }

    private static func percentile(sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = min(1, max(0, p)) * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let weight = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * weight
    }

    private static func percentDrift(from baseline: Double, to current: Double) -> Double {
        guard baseline > 0 else { return current > 0 ? 100 : 0 }
        return ((current - baseline) / baseline) * 100
    }

    private static func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
#endif
