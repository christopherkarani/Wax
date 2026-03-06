#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import Wax
@testable import WaxCore

final class RememberDedupBenchmarks: XCTestCase {
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
        let backgroundDocumentCount: Int
        let chunksPerDocument: Int
        let batchSize: Int
        let openIterations: Int
        let rememberIterations: Int
        let warmupIterations: Int
        let outputPath: String

        static func current() -> BenchmarkConfig {
            let env = ProcessInfo.processInfo.environment
            let scale = Scale.current()
            let defaultOutputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tasks")
                .appendingPathComponent("remember-dedup-benchmark.json")
                .path

            return BenchmarkConfig(
                scale: scale,
                backgroundDocumentCount: env["WAX_REMEMBER_DEDUP_BACKGROUND_DOCS"].flatMap(Int.init)
                    ?? (scale == .smoke ? 1_500 : 12_000),
                chunksPerDocument: env["WAX_REMEMBER_DEDUP_CHUNKS_PER_DOC"].flatMap(Int.init)
                    ?? (scale == .smoke ? 2 : 3),
                batchSize: env["WAX_REMEMBER_DEDUP_BATCH_SIZE"].flatMap(Int.init) ?? 256,
                openIterations: env["WAX_REMEMBER_DEDUP_OPEN_ITERATIONS"].flatMap(Int.init) ?? 7,
                rememberIterations: env["WAX_REMEMBER_DEDUP_ITERATIONS"].flatMap(Int.init)
                    ?? (scale == .smoke ? 9 : 21),
                warmupIterations: env["WAX_REMEMBER_DEDUP_WARMUP"].flatMap(Int.init) ?? 3,
                outputPath: env["WAX_BENCHMARK_REMEMBER_DEDUP_OUTPUT"] ?? defaultOutputPath
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
        let backgroundDocumentCount: Int
        let chunksPerDocument: Int
        let openLatencyMs: LatencySummary
        let rememberLatencyMs: LatencySummary
        let startRSSBytes: UInt64
        let endRSSBytes: UInt64
        let peakRSSBytes: UInt64
        let residentDeltaBytes: UInt64
        let before: StoreMetrics
        let after: StoreMetrics
    }

    func testLargeStoreRememberDedupMetrics() async throws {
        guard ProcessInfo.processInfo.environment["WAX_BENCHMARK_REMEMBER_DEDUP"] == "1" else {
            throw XCTSkip("Set WAX_BENCHMARK_REMEMBER_DEDUP=1 to run remember-dedup benchmarks.")
        }

        let config = BenchmarkConfig.current()
        let targetContent = "Scoped duplicate content must remain complete to short-circuit remember."
        let targetMetadata = ["scope": "target"]
        let orchestratorConfig = makeConfig()

        try await TempFiles.withTempFile { url in
            try await seedBackgroundStore(
                at: url,
                config: config,
                targetContent: targetContent,
                targetMetadata: targetMetadata,
                orchestratorConfig: orchestratorConfig
            )

            let before = try collectStoreMetrics(at: url)

            var openSamples: [Double] = []
            openSamples.reserveCapacity(config.openIterations)
            let clock = ContinuousClock()

            for _ in 0..<config.openIterations {
                let start = clock.now
                let orchestrator = try await MemoryOrchestrator(at: url, config: orchestratorConfig)
                openSamples.append(Self.durationMs(clock.now - start))
                try await orchestrator.close()
            }

            let orchestrator = try await MemoryOrchestrator(at: url, config: orchestratorConfig)
            for _ in 0..<config.warmupIterations {
                try await orchestrator.remember(targetContent, metadata: targetMetadata)
            }

            var rememberSamples: [Double] = []
            rememberSamples.reserveCapacity(config.rememberIterations)
            let startRSS = currentRSSBytes()
            var peakRSS = startRSS

            for _ in 0..<config.rememberIterations {
                let start = clock.now
                try await orchestrator.remember(targetContent, metadata: targetMetadata)
                rememberSamples.append(Self.durationMs(clock.now - start))
                peakRSS = max(peakRSS, currentRSSBytes())
            }

            let endRSS = currentRSSBytes()
            try await orchestrator.close()

            let after = try collectStoreMetrics(at: url)
            let report = BenchmarkReport(
                schemaVersion: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scale: config.scale.rawValue,
                backgroundDocumentCount: config.backgroundDocumentCount,
                chunksPerDocument: config.chunksPerDocument,
                openLatencyMs: .from(samples: openSamples),
                rememberLatencyMs: .from(samples: rememberSamples),
                startRSSBytes: startRSS,
                endRSSBytes: endRSS,
                peakRSSBytes: peakRSS,
                residentDeltaBytes: peakRSS >= startRSS ? (peakRSS - startRSS) : 0,
                before: before,
                after: after
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

    private func makeConfig() -> OrchestratorConfig {
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 6, overlapTokens: 0)
        return config
    }

    private func seedBackgroundStore(
        at url: URL,
        config: BenchmarkConfig,
        targetContent: String,
        targetMetadata: [String: String],
        orchestratorConfig: OrchestratorConfig
    ) async throws {
        let wax = try await Wax.create(at: url)
        let chunksPerDocument = max(1, config.chunksPerDocument)
        let batchSize = max(1, config.batchSize)

        for batchStart in stride(from: 0, to: config.backgroundDocumentCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, config.backgroundDocumentCount)
            let batchCount = batchEnd - batchStart

            var documentContents: [Data] = []
            var documentOptions: [FrameMetaSubset] = []
            documentContents.reserveCapacity(batchCount)
            documentOptions.reserveCapacity(batchCount)

            for index in batchStart..<batchEnd {
                let content = backgroundDocumentContent(documentIndex: index, chunksPerDocument: chunksPerDocument)
                let hash = ContentHasher.hash(Data(content.utf8)).hexString
                documentContents.append(Data(content.utf8))
                documentOptions.append(
                    FrameMetaSubset(
                        role: .document,
                        metadata: Metadata([
                            "scope": "background-\(index % 16)",
                            "wax.content.hash": hash,
                        ])
                    )
                )
            }

            let documentIDs = try await wax.putBatch(documentContents, options: documentOptions)

            var chunkContents: [Data] = []
            var chunkOptions: [FrameMetaSubset] = []
            chunkContents.reserveCapacity(batchCount * chunksPerDocument)
            chunkOptions.reserveCapacity(batchCount * chunksPerDocument)

            for (offset, documentID) in documentIDs.enumerated() {
                let documentIndex = batchStart + offset
                let chunkCount = UInt32(chunksPerDocument)
                for chunkIndex in 0..<chunksPerDocument {
                    let text = "background chunk \(documentIndex)-\(chunkIndex) repeated metadata probe ballast"
                    chunkContents.append(Data(text.utf8))
                    chunkOptions.append(
                        FrameMetaSubset(
                            role: .chunk,
                            parentId: documentID,
                            chunkIndex: UInt32(chunkIndex),
                            chunkCount: chunkCount,
                            searchText: text,
                            metadata: Metadata(["scope": "background-\(documentIndex % 16)"])
                        )
                    )
                }
            }

            _ = try await wax.putBatch(chunkContents, options: chunkOptions)
            try await wax.commit()
        }

        try await wax.close()

        let orchestrator = try await MemoryOrchestrator(at: url, config: orchestratorConfig)
        try await orchestrator.remember(targetContent, metadata: targetMetadata)
        try await orchestrator.flush()
        try await orchestrator.close()
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

    private func backgroundDocumentContent(documentIndex: Int, chunksPerDocument: Int) -> String {
        let base = "background document \(documentIndex) metadata dedup ballast"
        return Array(repeating: base, count: max(1, chunksPerDocument + 1)).joined(separator: " ")
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
