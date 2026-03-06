#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import Wax
@testable import WaxCore

final class SessionRuntimeStatsBenchmarks: XCTestCase {
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
        let batchSize: Int
        let activeSessionFrameCount: Int
        let iterations: Int
        let warmupIterations: Int
        let outputPath: String

        static func current() -> BenchmarkConfig {
            let env = ProcessInfo.processInfo.environment
            let scale = Scale.current()
            let defaultOutputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tasks")
                .appendingPathComponent("session-runtime-stats-benchmark.json")
                .path

            return BenchmarkConfig(
                scale: scale,
                backgroundFrameCount: env["WAX_SESSION_STATS_BACKGROUND_FRAMES"].flatMap(Int.init)
                    ?? (scale == .smoke ? 4_000 : 48_000),
                batchSize: env["WAX_SESSION_STATS_BATCH_SIZE"].flatMap(Int.init)
                    ?? (scale == .smoke ? 512 : 2_048),
                activeSessionFrameCount: env["WAX_SESSION_STATS_ACTIVE_FRAMES"].flatMap(Int.init)
                    ?? (scale == .smoke ? 4 : 8),
                iterations: env["WAX_SESSION_STATS_ITERATIONS"].flatMap(Int.init)
                    ?? (scale == .smoke ? 9 : 21),
                warmupIterations: env["WAX_SESSION_STATS_WARMUP"].flatMap(Int.init) ?? 3,
                outputPath: env["WAX_BENCHMARK_SESSION_STATS_OUTPUT"] ?? defaultOutputPath
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

    private struct ModeMetrics: Codable, Sendable {
        let latencyMs: LatencySummary
        let startRSSBytes: UInt64
        let endRSSBytes: UInt64
        let peakRSSBytes: UInt64
        let residentDeltaBytes: UInt64
    }

    private struct BenchmarkReport: Codable, Sendable {
        let schemaVersion: Int
        let generatedAt: String
        let scale: String
        let backgroundFrameCount: Int
        let activeSessionFrameCount: Int
        let legacy: ModeMetrics
        let optimized: ModeMetrics
        let store: StoreMetrics
    }

    func testLargeStoreSessionRuntimeStatsMetrics() async throws {
        guard ProcessInfo.processInfo.environment["WAX_BENCHMARK_SESSION_STATS"] == "1" else {
            throw XCTSkip("Set WAX_BENCHMARK_SESSION_STATS=1 to run session runtime stats benchmarks.")
        }

        let config = BenchmarkConfig.current()

        try await TempFiles.withTempFile { url in
            try await seedBackgroundStore(at: url, config: config)

            var orchestratorConfig = OrchestratorConfig.default
            orchestratorConfig.enableVectorSearch = false
            orchestratorConfig.enableTextSearch = false

            let orchestrator = try await MemoryOrchestrator(at: url, config: orchestratorConfig)
            let sessionID = await orchestrator.startSession().uuidString
            let wax = await orchestrator.wax

            try await seedSessionFrames(
                into: wax,
                sessionID: sessionID,
                activeFrameCount: config.activeSessionFrameCount
            )

            let expected = try await legacySessionRuntimeStats(wax: wax, sessionID: sessionID)
            let current = try await orchestrator.sessionRuntimeStats()
            XCTAssertEqual(current.sessionId?.uuidString, sessionID)
            XCTAssertEqual(current.sessionFrameCount, expected.sessionFrameCount)
            XCTAssertEqual(current.sessionTokenEstimate, expected.sessionTokenEstimate)
            XCTAssertEqual(current.pendingFramesStoreWide, expected.pendingFramesStoreWide)
            XCTAssertEqual(current.countsIncludePending, expected.countsIncludePending)

            for _ in 0..<config.warmupIterations {
                _ = try await legacySessionRuntimeStats(wax: wax, sessionID: sessionID)
                _ = try await orchestrator.sessionRuntimeStats()
            }

            let legacy = try await measureMode(iterations: config.iterations) {
                _ = try await self.legacySessionRuntimeStats(wax: wax, sessionID: sessionID)
            }
            let optimized = try await measureMode(iterations: config.iterations) {
                _ = try await orchestrator.sessionRuntimeStats()
            }

            XCTAssertLessThanOrEqual(
                optimized.latencyMs.p95Ms,
                legacy.latencyMs.p95Ms * 1.10 + 0.5,
                "Optimized sessionRuntimeStats p95 regressed materially versus legacy scan."
            )
            XCTAssertLessThanOrEqual(
                optimized.latencyMs.p99Ms,
                legacy.latencyMs.p99Ms * 1.10 + 0.5,
                "Optimized sessionRuntimeStats p99 regressed materially versus legacy scan."
            )

            let report = BenchmarkReport(
                schemaVersion: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scale: config.scale.rawValue,
                backgroundFrameCount: config.backgroundFrameCount,
                activeSessionFrameCount: config.activeSessionFrameCount,
                legacy: legacy,
                optimized: optimized,
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

            try await orchestrator.close()
        }
    }

    private func seedBackgroundStore(at url: URL, config: BenchmarkConfig) async throws {
        let wax = try await Wax.create(at: url)
        let batchSize = max(1, config.batchSize)

        for batchStart in stride(from: 0, to: config.backgroundFrameCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, config.backgroundFrameCount)
            for index in batchStart..<batchEnd {
                let content = "background frame \(index) ballast for session runtime stats"
                _ = try await wax.put(
                    Data(content.utf8),
                    options: FrameMetaSubset(
                        role: .document,
                        metadata: Metadata([
                            "scope": "background-\(index % 32)",
                        ])
                    )
                )
            }
            try await wax.commit()
        }

        try await wax.close()
    }

    private func seedSessionFrames(
        into wax: Wax,
        sessionID: String,
        activeFrameCount: Int
    ) async throws {
        for index in 0..<activeFrameCount {
            let content = "session active frame \(index)"
            _ = try await wax.put(
                Data(content.utf8),
                options: FrameMetaSubset(
                    role: .document,
                    metadata: Metadata(["session_id": sessionID])
                )
            )
        }

        let superseded = try await wax.put(
            Data("session superseded frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
        let replacement = try await wax.put(
            Data("session replacement frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
        try await wax.supersede(supersededId: superseded, supersedingId: replacement)

        let deleted = try await wax.put(
            Data("session deleted frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
        try await wax.delete(frameId: deleted)
        try await wax.commit()

        _ = try await wax.put(
            Data("session pending frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
    }

    private func legacySessionRuntimeStats(
        wax: Wax,
        sessionID: String
    ) async throws -> MemoryOrchestrator.SessionRuntimeStats {
        let pendingFramesStoreWide = await wax.stats().pendingFrames
        let metas = await wax.frameMetas()
        let matching = metas.filter { meta in
            guard meta.status == .active, meta.supersededBy == nil else { return false }
            return meta.metadata?.entries["session_id"] == sessionID
        }

        guard !matching.isEmpty else {
            return MemoryOrchestrator.SessionRuntimeStats(
                active: true,
                sessionId: UUID(uuidString: sessionID),
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let frameIDs = matching.map(\.id)
        let contentMap = try await wax.frameContents(frameIds: frameIDs)
        let texts: [String] = frameIDs.compactMap { frameID in
            guard let data = contentMap[frameID] else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let tokenCounter = try await TokenCounter.shared()
        let tokenCounts = await tokenCounter.countBatch(texts)
        let totalTokens = tokenCounts.reduce(0, +)

        return MemoryOrchestrator.SessionRuntimeStats(
            active: true,
            sessionId: UUID(uuidString: sessionID),
            sessionFrameCount: matching.count,
            sessionTokenEstimate: totalTokens,
            pendingFramesStoreWide: pendingFramesStoreWide,
            countsIncludePending: false
        )
    }

    private func measureMode(
        iterations: Int,
        operation: () async throws -> Void
    ) async throws -> ModeMetrics {
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        let startRSS = currentRSSBytes()
        var peakRSS = startRSS

        for _ in 0..<iterations {
            let start = clock.now
            try await operation()
            samples.append(Self.durationMs(clock.now - start))
            peakRSS = max(peakRSS, currentRSSBytes())
        }

        let endRSS = currentRSSBytes()
        return ModeMetrics(
            latencyMs: .from(samples: samples),
            startRSSBytes: startRSS,
            endRSSBytes: endRSS,
            peakRSSBytes: peakRSS,
            residentDeltaBytes: peakRSS >= startRSS ? (peakRSS - startRSS) : 0
        )
    }

    private func collectStoreMetrics(at url: URL) throws -> StoreMetrics {
        let freshURL = URL(fileURLWithPath: url.path).standardizedFileURL
        let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let logicalBytes = UInt64(max(0, values.fileSize ?? 0))
        let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        let allocatedBytes = UInt64(max(0, allocatedValue))

        let footerSlice = try XCTUnwrap(try FooterScanner.findLastValidFooter(in: freshURL))
        let toc = try WaxTOC.decode(from: footerSlice.tocBytes)
        let totalPayloadBytes = toc.frames.reduce(into: UInt64(0)) { partial, frame in
            partial &+= frame.payloadLength
        }
        let deadPayloadBytes = toc.frames.reduce(into: UInt64(0)) { partial, frame in
            let isLive = frame.status == .active && frame.supersededBy == nil
            if !isLive {
                partial &+= frame.payloadLength
            }
        }
        let deadPayloadFraction = totalPayloadBytes == 0
            ? 0
            : Double(deadPayloadBytes) / Double(totalPayloadBytes)

        return StoreMetrics(
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            deadPayloadBytes: deadPayloadBytes,
            deadPayloadFraction: deadPayloadFraction,
            tocBytes: footerSlice.tocBytes.count,
            frameCount: UInt64(toc.frames.count),
            segmentCatalogEntryCount: toc.segmentCatalog.entries.count
        )
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
