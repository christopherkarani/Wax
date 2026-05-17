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

    private enum StabilitySearchMode: String, Codable, Sendable {
        case text
        case vector
        case hybrid

        var usesText: Bool {
            switch self {
            case .text, .hybrid: true
            case .vector: false
            }
        }

        var usesVector: Bool {
            switch self {
            case .vector, .hybrid: true
            case .text: false
            }
        }

        var searchMode: SearchMode {
            switch self {
            case .text: .textOnly
            case .vector: .vectorOnly
            case .hybrid: .hybrid(alpha: 0.5)
            }
        }

        static func fromEnvironment(_ env: [String: String]) throws -> Self {
            let raw = env["WAX_STABILITY_SEARCH_MODE"] ?? Self.hybrid.rawValue
            guard let mode = Self(rawValue: raw) else {
                throw NSError(
                    domain: "ProductionReadinessStabilityTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported WAX_STABILITY_SEARCH_MODE '\(raw)'; expected text, vector, or hybrid."]
                )
            }
            return mode
        }
    }

    private struct LatencySummary: Codable, Sendable {
        let samples: Int
        let meanMs: Double
        let p50Ms: Double
        let p95Ms: Double
    }

    private struct StabilityReport: Codable, Sendable {
        let profile: String
        let searchMode: StabilitySearchMode
        let replaySeed: UInt64
        let replaySteps: Int
        let recallSamples: Int
        let vectorSourceHits: Int
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
        let searchMode = try StabilitySearchMode.fromEnvironment(env)

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
        let vector = searchMode.usesVector
            ? try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)
            : nil

        let startRSS = currentRSSBytes()
        let clock = ContinuousClock()

        var recallLatenciesMs: [Double] = []
        recallLatenciesMs.reserveCapacity(plan.steps.count / 4)
        var vectorSourceHits = 0

        var ingestCount = 0
        var pendingSinceCommit = 0

        for step in plan.steps {
            switch step.action {
            case .ingest:
                let options = FrameMetaSubset(searchText: step.payload)
                let frameID: UInt64
                if let vector {
                    frameID = try await vector.putWithEmbedding(
                        Data(step.payload.utf8),
                        embedding: Self.deterministicEmbedding(for: step.payload),
                        options: options
                    )
                } else {
                    frameID = try await wax.put(
                        Data(step.payload.utf8),
                        options: options
                    )
                }
                try await text.index(frameId: frameID, text: step.payload)
                ingestCount += 1
                pendingSinceCommit += 1
                if pendingSinceCommit >= commitBatch {
                    try await text.stageForCommit()
                    if let vector {
                        try await vector.stageForCommit()
                    }
                    try await wax.commit()
                    pendingSinceCommit = 0
                }
            case .recall:
                guard ingestCount > 0 else { continue }
                let start = clock.now
                let response = try await wax.search(
                    SearchRequest(
                        query: searchMode.usesText ? step.payload : nil,
                        embedding: searchMode.usesVector ? Self.deterministicEmbedding(for: step.payload) : nil,
                        vectorEnginePreference: .cpuOnly,
                        mode: searchMode.searchMode,
                        topK: 8
                    )
                )
                vectorSourceHits += response.results.filter { $0.sources.contains(.vector) }.count
                let elapsed = clock.now - start
                recallLatenciesMs.append(Self.durationMs(elapsed))
            }
        }

        if pendingSinceCommit > 0 {
            try await text.stageForCommit()
            if let vector {
                try await vector.stageForCommit()
            }
            try await wax.commit()
        }

        let endRSS = currentRSSBytes()
        try await wax.close()

        XCTAssertGreaterThanOrEqual(recallLatenciesMs.count, 20, "Need enough recall samples to measure drift")
        if searchMode.usesVector {
            XCTAssertGreaterThan(vectorSourceHits, 0, "Stability profile must exercise vector-sourced search results in \(searchMode.rawValue) mode")
        }
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
            searchMode: searchMode,
            replaySeed: plan.seed,
            replaySteps: plan.steps.count,
            recallSamples: recallLatenciesMs.count,
            vectorSourceHits: vectorSourceHits,
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
            mode=\(report.searchMode.rawValue) vector_hits=\(report.vectorSourceHits) \
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

    private static func deterministicEmbedding(for text: String) -> [Float] {
        let topic = stabilityTopics.firstIndex { text.localizedCaseInsensitiveContains($0) } ?? 0
        let radians = (Double(topic) / Double(stabilityTopics.count)) * 2.0 * Double.pi
        return VectorMath.normalizeL2([Float(cos(radians)), Float(sin(radians))])
    }

    private static let stabilityTopics = [
        "swift",
        "vector",
        "memory",
        "wal",
        "replay",
        "compaction",
        "deterministic",
        "latency",
        "checksum",
    ]

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
