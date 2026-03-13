#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import Wax
@testable import WaxCore

final class HandoffLookupBenchmarks: XCTestCase {
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
        let handoffCount: Int
        let batchSize: Int
        let projectModulo: Int
        let iterations: Int
        let warmupIterations: Int
        let outputPath: String

        static func current() -> BenchmarkConfig {
            let env = ProcessInfo.processInfo.environment
            let scale = Scale.current()
            let defaultOutputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tasks")
                .appendingPathComponent("handoff-lookup-benchmark.json")
                .path

            return BenchmarkConfig(
                scale: scale,
                backgroundFrameCount: env["WAX_HANDOFF_LOOKUP_BACKGROUND_FRAMES"].flatMap(Int.init)
                    ?? (scale == .smoke ? 4_000 : 48_000),
                handoffCount: env["WAX_HANDOFF_LOOKUP_HANDOFFS"].flatMap(Int.init)
                    ?? (scale == .smoke ? 256 : 4_096),
                batchSize: env["WAX_HANDOFF_LOOKUP_BATCH_SIZE"].flatMap(Int.init)
                    ?? (scale == .smoke ? 512 : 2_048),
                projectModulo: env["WAX_HANDOFF_LOOKUP_PROJECT_MODULO"].flatMap(Int.init) ?? 32,
                iterations: env["WAX_HANDOFF_LOOKUP_ITERATIONS"].flatMap(Int.init)
                    ?? (scale == .smoke ? 9 : 21),
                warmupIterations: env["WAX_HANDOFF_LOOKUP_WARMUP"].flatMap(Int.init) ?? 3,
                outputPath: env["WAX_BENCHMARK_HANDOFF_LOOKUP_OUTPUT"] ?? defaultOutputPath
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

    private struct ModeMetrics: Codable, Sendable {
        let latencyMs: LatencySummary
        let startRSSBytes: UInt64
        let endRSSBytes: UInt64
        let peakRSSBytes: UInt64
        let residentDeltaBytes: UInt64
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
        let targetProject: String
        let backgroundFrameCount: Int
        let handoffCount: Int
        let legacy: ModeMetrics
        let optimized: ModeMetrics
        let store: StoreMetrics
    }

    func testLatestHandoffLookupMetrics() async throws {
        guard ProcessInfo.processInfo.environment["WAX_BENCHMARK_HANDOFF_LOOKUP"] == "1" else {
            throw XCTSkip("Set WAX_BENCHMARK_HANDOFF_LOOKUP=1 to run handoff lookup benchmarks.")
        }

        let config = BenchmarkConfig.current()
        let targetProject = "project-\(max(1, config.projectModulo) / 2)"

        try await TempFiles.withTempFile { url in
            try await seedStore(at: url, config: config)
            let wax = try await Wax.open(at: url)

            let legacy = await legacyLatestHandoffMeta(wax: wax, project: targetProject)
            let optimized = await wax.latestCommittedActiveHandoffMeta(project: targetProject)
            XCTAssertEqual(optimized?.id, legacy?.id)
            XCTAssertEqual(optimized?.timestamp, legacy?.timestamp)

            for _ in 0..<config.warmupIterations {
                _ = await legacyLatestHandoffMeta(wax: wax, project: targetProject)
                _ = await wax.latestCommittedActiveHandoffMeta(project: targetProject)
            }

            let legacyMetrics = try await measureMode(iterations: config.iterations) {
                _ = await self.legacyLatestHandoffMeta(wax: wax, project: targetProject)
            }
            let optimizedMetrics = try await measureMode(iterations: config.iterations) {
                _ = await wax.latestCommittedActiveHandoffMeta(project: targetProject)
            }

            XCTAssertLessThanOrEqual(
                optimizedMetrics.latencyMs.p95Ms,
                legacyMetrics.latencyMs.p95Ms * 1.10 + 0.5,
                "Optimized latestHandoff lookup p95 regressed materially versus legacy frameMetas filtering."
            )
            XCTAssertLessThanOrEqual(
                optimizedMetrics.latencyMs.p99Ms,
                legacyMetrics.latencyMs.p99Ms * 1.10 + 0.5,
                "Optimized latestHandoff lookup p99 regressed materially versus legacy frameMetas filtering."
            )

            let report = BenchmarkReport(
                schemaVersion: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scale: config.scale.rawValue,
                targetProject: targetProject,
                backgroundFrameCount: config.backgroundFrameCount,
                handoffCount: config.handoffCount,
                legacy: legacyMetrics,
                optimized: optimizedMetrics,
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

            try await wax.close()
        }
    }

    private func seedStore(at url: URL, config: BenchmarkConfig) async throws {
        let wax = try await Wax.create(at: url)
        let batchSize = max(1, config.batchSize)
        let projectModulo = max(1, config.projectModulo)

        for batchStart in stride(from: 0, to: config.backgroundFrameCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, config.backgroundFrameCount)
            for index in batchStart..<batchEnd {
                let content = "background frame \(index) ballast for handoff lookup"
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

        let baseTimestamp: Int64 = 1_700_000_000_000
        for batchStart in stride(from: 0, to: config.handoffCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, config.handoffCount)

            for index in batchStart..<batchEnd {
                let project = "project-\(index % projectModulo)"
                let content = "handoff \(index) for \(project)"
                let metadata = Metadata([
                    "project": project,
                    "pending_tasks": "task-\(index)",
                ])
                let timestamp = baseTimestamp + Int64(index)

                let options: FrameMetaSubset
                switch index % 3 {
                case 0:
                    options = FrameMetaSubset(
                        kind: "handoff",
                        labels: ["handoff"],
                        role: .document,
                        metadata: metadata
                    )
                case 1:
                    options = FrameMetaSubset(
                        role: .document,
                        metadata: {
                            var metadata = metadata
                            metadata.entries["kind"] = "handoff"
                            return metadata
                        }()
                    )
                default:
                    options = FrameMetaSubset(
                        labels: ["handoff"],
                        role: .document,
                        metadata: metadata
                    )
                }

                let frameID = try await wax.put(Data(content.utf8), options: options, timestampMs: timestamp)
                if index % 11 == 0 {
                    try await wax.delete(frameId: frameID)
                } else if index % 13 == 0 {
                    let replacementProject = "project-\((index + 1) % projectModulo)"
                    let replacementID = try await wax.put(
                        Data("replacement \(index)".utf8),
                        options: FrameMetaSubset(
                            kind: "handoff",
                            labels: ["handoff"],
                            role: .document,
                            metadata: Metadata([
                                "kind": "handoff",
                                "project": replacementProject,
                                "pending_tasks": "replacement-task-\(index)",
                            ])
                        ),
                        timestampMs: timestamp + 1
                    )
                    try await wax.supersede(supersededId: frameID, supersedingId: replacementID)
                }
            }

            try await wax.commit()
        }

        try await wax.close()
    }

    private func legacyLatestHandoffMeta(wax: Wax, project: String?) async -> FrameMeta? {
        let metas = await wax.frameMetas()
        let filtered = metas.filter { meta in
            guard meta.status == .active, meta.supersededBy == nil else { return false }
            let hasHandoffKind = meta.kind == "handoff" || meta.metadata?.entries["kind"] == "handoff"
            let hasHandoffLabel = meta.labels.contains("handoff")
            guard hasHandoffKind || hasHandoffLabel else { return false }
            if let project, !project.isEmpty {
                return meta.metadata?.entries["project"] == project
            }
            return true
        }

        return filtered.max(by: { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id < rhs.id
            }
            return lhs.timestamp < rhs.timestamp
        })
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
            let started = clock.now
            try await operation()
            samples.append(Self.durationMs(clock.now - started))
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

    private static func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
#endif
