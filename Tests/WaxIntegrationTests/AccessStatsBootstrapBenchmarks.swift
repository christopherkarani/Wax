#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import Wax
@testable import WaxCore

final class AccessStatsBootstrapBenchmarks: XCTestCase {
    private enum Scale: String {
        case smoke
        case standard

        static func current() -> Scale {
            let raw = ProcessInfo.processInfo.environment["WAX_BENCHMARK_SCALE"]?.lowercased()
            switch raw {
            case "smoke", "quick":
                return .smoke
            default:
                return .standard
            }
        }
    }

    private struct BenchmarkConfig {
        let scale: Scale
        let backgroundFrameCount: Int
        let trackedFrameCount: Int
        let batchSize: Int
        let openIterations: Int
        let warmupIterations: Int
        let outputPath: String

        static func current() -> BenchmarkConfig {
            let env = ProcessInfo.processInfo.environment
            let scale = Scale.current()
            let defaultOutputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tasks")
                .appendingPathComponent("access-stats-bootstrap-benchmark.json")
                .path

            return BenchmarkConfig(
                scale: scale,
                backgroundFrameCount: env["WAX_ACCESS_STATS_BOOTSTRAP_BACKGROUND_FRAMES"].flatMap(Int.init)
                    ?? (scale == .smoke ? 4_000 : 48_000),
                trackedFrameCount: env["WAX_ACCESS_STATS_BOOTSTRAP_TRACKED_FRAMES"].flatMap(Int.init)
                    ?? (scale == .smoke ? 32 : 256),
                batchSize: env["WAX_ACCESS_STATS_BOOTSTRAP_BATCH_SIZE"].flatMap(Int.init)
                    ?? (scale == .smoke ? 512 : 2_048),
                openIterations: env["WAX_ACCESS_STATS_BOOTSTRAP_OPEN_ITERATIONS"].flatMap(Int.init)
                    ?? (scale == .smoke ? 9 : 21),
                warmupIterations: env["WAX_ACCESS_STATS_BOOTSTRAP_WARMUP"].flatMap(Int.init) ?? 3,
                outputPath: env["WAX_BENCHMARK_ACCESS_STATS_BOOTSTRAP_OUTPUT"] ?? defaultOutputPath
            )
        }
    }

    private struct LatencySummary: Codable, Sendable {
        let samples: Int
        let meanMs: Double
        let p50Ms: Double
        let p95Ms: Double
        let p99Ms: Double
        let minMs: Double
        let maxMs: Double
        let stdevMs: Double

        static func from(samples: [Double]) -> LatencySummary {
            guard !samples.isEmpty else {
                return LatencySummary(
                    samples: 0,
                    meanMs: 0,
                    p50Ms: 0,
                    p95Ms: 0,
                    p99Ms: 0,
                    minMs: 0,
                    maxMs: 0,
                    stdevMs: 0
                )
            }

            let sorted = samples.sorted()
            let count = Double(samples.count)
            let mean = samples.reduce(0, +) / count
            let variance = samples.reduce(0) { partial, sample in
                let delta = sample - mean
                return partial + (delta * delta)
            } / count

            return LatencySummary(
                samples: samples.count,
                meanMs: mean,
                p50Ms: percentile(sorted: sorted, p: 0.50),
                p95Ms: percentile(sorted: sorted, p: 0.95),
                p99Ms: percentile(sorted: sorted, p: 0.99),
                minMs: sorted.first ?? 0,
                maxMs: sorted.last ?? 0,
                stdevMs: sqrt(variance)
            )
        }

        private static func percentile(sorted: [Double], p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            if sorted.count == 1 { return sorted[0] }
            let clamped = min(1, max(0, p))
            let rank = clamped * Double(sorted.count - 1)
            let lower = Int(rank.rounded(.down))
            let upper = Int(rank.rounded(.up))
            if lower == upper { return sorted[lower] }
            let weight = rank - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
        }
    }

    private struct StoreMetrics: Codable, Sendable {
        let logicalBytes: UInt64
        let allocatedBytes: UInt64
        let deadPayloadBytes: UInt64
        let deadPayloadFraction: Double
        let tocBytes: Int
        let frameCount: UInt64
        let segmentCatalogEntryCount: Int
    }

    private struct BenchmarkReport: Codable, Sendable {
        let schemaVersion: Int
        let generatedAt: String
        let scale: String
        let backgroundFrameCount: Int
        let trackedFrameCount: Int
        let openLatencyMs: LatencySummary
        let startRSSBytes: UInt64
        let endRSSBytes: UInt64
        let peakRSSBytes: UInt64
        let residentDeltaBytes: UInt64
        let store: StoreMetrics
    }

    func testAccessStatsBootstrapOpenMetrics() async throws {
        guard ProcessInfo.processInfo.environment["WAX_BENCHMARK_ACCESS_STATS_BOOTSTRAP"] == "1" else {
            throw XCTSkip("Set WAX_BENCHMARK_ACCESS_STATS_BOOTSTRAP=1 to run access-stats bootstrap benchmarks.")
        }

        let config = BenchmarkConfig.current()

        try await TempFiles.withTempFile { url in
            try await seedStore(at: url, config: config)

            var orchestratorConfig = OrchestratorConfig.default
            orchestratorConfig.enableVectorSearch = false
            orchestratorConfig.enableAccessStatsScoring = true

            for _ in 0..<config.warmupIterations {
                let orchestrator = try await MemoryOrchestrator(at: url, config: orchestratorConfig)
                try await orchestrator.close()
            }

            let clock = ContinuousClock()
            var openSamples: [Double] = []
            openSamples.reserveCapacity(config.openIterations)
            let startRSS = currentRSSBytes()
            var peakRSS = startRSS

            for _ in 0..<config.openIterations {
                let started = clock.now
                let orchestrator = try await MemoryOrchestrator(at: url, config: orchestratorConfig)
                openSamples.append(Self.durationMs(clock.now - started))
                peakRSS = max(peakRSS, currentRSSBytes())
                try await orchestrator.close()
            }

            let endRSS = currentRSSBytes()
            let report = BenchmarkReport(
                schemaVersion: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scale: config.scale.rawValue,
                backgroundFrameCount: config.backgroundFrameCount,
                trackedFrameCount: config.trackedFrameCount,
                openLatencyMs: .from(samples: openSamples),
                startRSSBytes: startRSS,
                endRSSBytes: endRSS,
                peakRSSBytes: peakRSS,
                residentDeltaBytes: peakRSS >= startRSS ? (peakRSS - startRSS) : 0,
                store: try collectStoreMetrics(at: url)
            )

            let outputURL = URL(fileURLWithPath: config.outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        }
    }

    private func seedStore(at url: URL, config: BenchmarkConfig) async throws {
        let wax = try await Wax.create(at: url)
        let batchSize = max(1, config.batchSize)

        for batchStart in stride(from: 0, to: config.backgroundFrameCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, config.backgroundFrameCount)
            for index in batchStart..<batchEnd {
                let content = "background frame \(index) ballast for access-stats bootstrap"
                _ = try await wax.put(
                    Data(content.utf8),
                    options: FrameMetaSubset(
                        role: .document,
                        searchText: content
                    )
                )
            }
            try await wax.commit()
        }

        let trackedCount = min(config.trackedFrameCount, config.backgroundFrameCount)
        var stats: [FrameAccessStats] = []
        stats.reserveCapacity(trackedCount)
        for frameID in 0..<trackedCount {
            var stat = FrameAccessStats(frameId: UInt64(frameID), nowMs: 1_700_000_000_000)
            stat.recordAccess(nowMs: 1_700_000_000_500)
            stats.append(stat)
        }

        let payload = try JSONEncoder().encode(stats)
        _ = try await wax.put(
            payload,
            options: FrameMetaSubset(
                role: .system,
                metadata: Metadata(["wax.internal.kind": "access_stats"])
            )
        )
        try await wax.commit()
        try await wax.close()
    }

    private func collectStoreMetrics(at url: URL) throws -> StoreMetrics {
        let freshURL = URL(fileURLWithPath: url.path).standardizedFileURL
        let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let logicalBytes = UInt64(max(0, values.fileSize ?? 0))
        let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        let allocatedBytes = UInt64(max(0, allocatedValue))

        let footerSlice = try XCTUnwrap(try FooterScanner.findLastValidFooter(in: freshURL))
        let toc = try WaxTOC.decode(from: footerSlice.tocBytes)
        let deadPayloadBytes = toc.frames.reduce(into: UInt64(0)) { total, frame in
            if frame.status != .active || frame.supersededBy != nil {
                total &+= frame.payloadLength
            }
        }
        let totalPayloadBytes = toc.frames.reduce(into: UInt64(0)) { $0 &+= $1.payloadLength }
        let deadPayloadFraction = totalPayloadBytes > 0
            ? Double(deadPayloadBytes) / Double(totalPayloadBytes)
            : 0

        let segmentCount = toc.segmentCatalog.entries.count
        let frameCount = UInt64(toc.frames.count)

        return StoreMetrics(
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            deadPayloadBytes: deadPayloadBytes,
            deadPayloadFraction: deadPayloadFraction,
            tocBytes: footerSlice.tocBytes.count,
            frameCount: frameCount,
            segmentCatalogEntryCount: segmentCount
        )
    }

    private func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static func durationMs(_ duration: ContinuousClock.Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
#endif
