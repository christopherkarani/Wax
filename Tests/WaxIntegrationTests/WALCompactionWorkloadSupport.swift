import Foundation
@testable import Wax
import WaxCore

enum WALCompactionWorkloadMode: String, Codable, Sendable {
    case textOnly = "text_only"
    case hybrid = "hybrid"
}

enum WALCompactionBenchmarkScale: String, Sendable {
    case smoke
    case standard

    static func current() -> WALCompactionBenchmarkScale {
        let raw = ProcessInfo.processInfo.environment["WAX_BENCHMARK_SCALE"]?.lowercased()
        switch raw {
        case "smoke", "quick":
            return .smoke
        default:
            return .standard
        }
    }
}

struct WALCompactionBenchmarkConfig: Sendable {
    let scale: WALCompactionBenchmarkScale
    let sampleEveryWrites: Int
    let reopenIterations: Int
    let outputPath: String

    static func current() -> WALCompactionBenchmarkConfig {
        let env = ProcessInfo.processInfo.environment
        let defaultOutputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tasks")
            .appendingPathComponent("wal-compaction-baseline.json")
            .path

        return WALCompactionBenchmarkConfig(
            scale: WALCompactionBenchmarkScale.current(),
            sampleEveryWrites: max(1, env["WAX_WAL_SAMPLE_EVERY_WRITES"].flatMap(Int.init) ?? 250),
            reopenIterations: max(1, env["WAX_WAL_REOPEN_ITERATIONS"].flatMap(Int.init) ?? 7),
            outputPath: env["WAX_BENCHMARK_WAL_OUTPUT"] ?? defaultOutputPath
        )
    }
}

struct WALCompactionWorkload: Codable, Sendable {
    let name: String
    let mode: WALCompactionWorkloadMode
    let totalWrites: Int
    let commitEveryWrites: Int?
    let walSize: UInt64
    let payloadBytes: Int
    let vectorDimensions: Int

    static func matrix(scale: WALCompactionBenchmarkScale) -> [WALCompactionWorkload] {
        let entries: [WALCompactionWorkload] = [
            .init(
                name: "small_text",
                mode: .textOnly,
                totalWrites: 500,
                commitEveryWrites: 50,
                walSize: Constants.defaultWalSize,
                payloadBytes: 320,
                vectorDimensions: 0
            ),
            .init(
                name: "small_hybrid",
                mode: .hybrid,
                totalWrites: 500,
                commitEveryWrites: 50,
                walSize: Constants.defaultWalSize,
                payloadBytes: 320,
                vectorDimensions: 128
            ),
            .init(
                name: "medium_text",
                mode: .textOnly,
                totalWrites: 5_000,
                commitEveryWrites: 100,
                walSize: Constants.defaultWalSize,
                payloadBytes: 384,
                vectorDimensions: 0
            ),
            .init(
                name: "medium_hybrid",
                mode: .hybrid,
                totalWrites: 5_000,
                commitEveryWrites: 100,
                walSize: Constants.defaultWalSize,
                payloadBytes: 384,
                vectorDimensions: 128
            ),
            .init(
                name: "large_text_10k",
                mode: .textOnly,
                totalWrites: 10_000,
                commitEveryWrites: 200,
                walSize: Constants.defaultWalSize,
                payloadBytes: 384,
                vectorDimensions: 0
            ),
            .init(
                name: "large_hybrid_10k",
                mode: .hybrid,
                totalWrites: 10_000,
                commitEveryWrites: 200,
                walSize: Constants.defaultWalSize,
                payloadBytes: 384,
                vectorDimensions: 128
            ),
            .init(
                name: "sustained_write_text",
                mode: .textOnly,
                totalWrites: 30_000,
                commitEveryWrites: nil,
                walSize: 512 * 1024,
                payloadBytes: 256,
                vectorDimensions: 0
            ),
            .init(
                name: "sustained_write_hybrid",
                mode: .hybrid,
                totalWrites: 10_000,
                commitEveryWrites: 64,
                walSize: 512 * 1024,
                payloadBytes: 256,
                vectorDimensions: 128
            ),
        ]

        guard scale == .smoke else { return entries }
        return entries.map { workload in
            WALCompactionWorkload(
                name: workload.name,
                mode: workload.mode,
                totalWrites: max(100, workload.totalWrites / 10),
                commitEveryWrites: workload.commitEveryWrites.map { max(10, $0 / 5) },
                walSize: workload.walSize,
                payloadBytes: workload.payloadBytes,
                vectorDimensions: workload.vectorDimensions
            )
        }
    }
}

struct WALCompactionLatencySummary: Codable, Sendable {
    let samples: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let minMs: Double
    let maxMs: Double
    let stdevMs: Double

    static func from(samples: [Double]) -> WALCompactionLatencySummary {
        guard !samples.isEmpty else {
            return WALCompactionLatencySummary(
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
        let variance = samples.reduce(0) { partial, value in
            let delta = value - mean
            return partial + (delta * delta)
        } / count

        return WALCompactionLatencySummary(
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

struct WALCompactionPressureSummary: Codable, Sendable {
    let sampleCount: Int
    let pendingBytesMean: Double
    let pendingBytesMax: UInt64
    let pendingBytesP95: UInt64
    let wrapCount: UInt64
    let checkpointCount: UInt64
    let autoCommitCount: UInt64
    let sentinelWriteCount: UInt64
    let writeCallCount: UInt64
    let replaySnapshotHitCount: UInt64
}

struct WALCompactionFileGrowthPoint: Codable, Sendable {
    let writesCompleted: Int
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let pendingBytes: UInt64
    let checkpointCount: UInt64
    let timestampMs: Int64
}

struct WALCompactionHealthSummary: Codable, Sendable {
    let verifyPassed: Bool
    let reopenFrameCountMatches: Bool
    let expectedFrameCount: UInt64
    let reopenedFrameCount: UInt64
    let notes: [String]
}

struct WALCompactionWorkloadResult: Codable, Sendable {
    let workload: WALCompactionWorkload
    let durationMs: Double
    let putLatencyMs: WALCompactionLatencySummary
    let stageLatencyMs: WALCompactionLatencySummary
    let commitLatencyMs: WALCompactionLatencySummary
    let autoCommitPutLatencyMs: WALCompactionLatencySummary
    let pressure: WALCompactionPressureSummary
    let growth: [WALCompactionFileGrowthPoint]
    let finalLogicalBytes: UInt64
    let finalAllocatedBytes: UInt64
    let reopenLatencyMs: WALCompactionLatencySummary
    let health: WALCompactionHealthSummary
}

struct WALCompactionBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let scale: String
    let workloads: [WALCompactionWorkloadResult]
}

enum WALCompactionReportWriter {
    static func write(_ report: WALCompactionBenchmarkReport, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }
}

actor WALCompactionDeterministicEmbedder: EmbeddingProvider {
    let dimensions: Int
    let normalize: Bool
    let identity: EmbeddingIdentity?

    init(dimensions: Int, normalize: Bool = true) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = EmbeddingIdentity(
            provider: "wal-bench",
            model: "fnv1a-lcg",
            dimensions: dimensions,
            normalized: normalize
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        var state = Self.fnv1a64(Array(text.utf8))
        var vector = [Float](repeating: 0, count: dimensions)
        for idx in vector.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let signed = Int64(bitPattern: state)
            vector[idx] = Float(signed) / Float(Int64.max)
        }
        return normalize ? VectorMath.normalizeL2(vector) : vector
    }

    private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}

enum WALCompactionHarness {
    static func run(
        workload: WALCompactionWorkload,
        sampleEveryWrites: Int,
        reopenIterations: Int,
        waxOptions: WaxOptions = .init()
    ) async throws -> WALCompactionWorkloadResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-compaction-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        let clock = ContinuousClock()
        let started = clock.now

        let wax = try await Wax.create(at: url, walSize: workload.walSize, options: waxOptions)
        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: workload.mode == .hybrid,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: workload.mode == .hybrid ? workload.vectorDimensions : nil
        )
        let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)
        let embedder = workload.mode == .hybrid
            ? WALCompactionDeterministicEmbedder(dimensions: workload.vectorDimensions)
            : nil

        var putLatenciesMs: [Double] = []
        putLatenciesMs.reserveCapacity(workload.totalWrites)
        var stageLatenciesMs: [Double] = []
        var commitLatenciesMs: [Double] = []
        var autoCommitPutLatenciesMs: [Double] = []
        var pendingBytesSamples: [UInt64] = []
        pendingBytesSamples.reserveCapacity(workload.totalWrites)
        var growth: [WALCompactionFileGrowthPoint] = []

        var lastAutoCommitCount = (await wax.walStats()).autoCommitCount
        let startSizes = try fileSizes(at: url)
        growth.append(
            WALCompactionFileGrowthPoint(
                writesCompleted: 0,
                logicalBytes: startSizes.logical,
                allocatedBytes: startSizes.allocated,
                pendingBytes: 0,
                checkpointCount: 0,
                timestampMs: nowMs()
            )
        )

        for index in 0..<workload.totalWrites {
            let text = documentText(for: index, workload: workload)
            let payload = Data(text.utf8)
            let options = FrameMetaSubset(searchText: text)

            let putStart = clock.now
            let frameId: UInt64
            if let embedder {
                let embedding = try await embedder.embed(text)
                frameId = try await session.put(
                    payload,
                    embedding: embedding,
                    identity: embedder.identity,
                    options: options
                )
            } else {
                frameId = try await session.put(payload, options: options)
            }
            try await session.indexText(frameId: frameId, text: text)
            let putDurationMs = durationMs(clock.now - putStart)
            putLatenciesMs.append(putDurationMs)

            let walStats = await wax.walStats()
            pendingBytesSamples.append(walStats.pendingBytes)
            if walStats.autoCommitCount > lastAutoCommitCount {
                autoCommitPutLatenciesMs.append(putDurationMs)
                lastAutoCommitCount = walStats.autoCommitCount
            }

            let writesCompleted = index + 1
            if let commitEvery = workload.commitEveryWrites,
               writesCompleted % commitEvery == 0 {
                let stageStart = clock.now
                try await session.stage()
                stageLatenciesMs.append(durationMs(clock.now - stageStart))

                let commitStart = clock.now
                try await wax.commit()
                commitLatenciesMs.append(durationMs(clock.now - commitStart))
            }

            if writesCompleted % max(1, sampleEveryWrites) == 0 || writesCompleted == workload.totalWrites {
                let sizes = try fileSizes(at: url)
                growth.append(
                    WALCompactionFileGrowthPoint(
                        writesCompleted: writesCompleted,
                        logicalBytes: sizes.logical,
                        allocatedBytes: sizes.allocated,
                        pendingBytes: walStats.pendingBytes,
                        checkpointCount: walStats.checkpointCount,
                        timestampMs: nowMs()
                    )
                )
            }
        }

        let statsBeforeFinalCommit = await wax.walStats()
        if statsBeforeFinalCommit.pendingBytes > 0 {
            let stageStart = clock.now
            try await session.stage()
            stageLatenciesMs.append(durationMs(clock.now - stageStart))

            let commitStart = clock.now
            try await wax.commit()
            commitLatenciesMs.append(durationMs(clock.now - commitStart))
        }

        let finalWalStats = await wax.walStats()
        let finalSizes = try fileSizes(at: url)

        var healthNotes: [String] = []
        var verifyPassed = true
        do {
            try await wax.verify(deep: false)
        } catch {
            verifyPassed = false
            healthNotes.append("verify_failed: \(error)")
        }

        await session.close()
        try await wax.close()

        var reopenSamplesMs: [Double] = []
        reopenSamplesMs.reserveCapacity(reopenIterations)
        var reopenedFrameCount: UInt64 = 0
        var reopenFrameCountMatches = false

        for index in 0..<max(1, reopenIterations) {
            let reopenStart = clock.now
            let reopened = try await Wax.open(at: url)
            let elapsedMs = durationMs(clock.now - reopenStart)
            reopenSamplesMs.append(elapsedMs)

            if index == 0 {
                reopenedFrameCount = (await reopened.stats()).frameCount
                reopenFrameCountMatches = reopenedFrameCount == UInt64(workload.totalWrites)
                if !reopenFrameCountMatches {
                    healthNotes.append(
                        "reopen_frame_count_mismatch expected=\(workload.totalWrites) actual=\(reopenedFrameCount)"
                    )
                }
            }

            try await reopened.close()
        }

        let pendingAsDouble = pendingBytesSamples.map { Double($0) }
        let pendingP95 = pendingBytesSamples.isEmpty
            ? UInt64(0)
            : UInt64(WALCompactionLatencySummary.from(samples: pendingAsDouble).p95Ms.rounded())

        let pressure = WALCompactionPressureSummary(
            sampleCount: pendingBytesSamples.count,
            pendingBytesMean: pendingAsDouble.isEmpty ? 0 : pendingAsDouble.reduce(0, +) / Double(pendingAsDouble.count),
            pendingBytesMax: pendingBytesSamples.max() ?? 0,
            pendingBytesP95: pendingP95,
            wrapCount: finalWalStats.wrapCount,
            checkpointCount: finalWalStats.checkpointCount,
            autoCommitCount: finalWalStats.autoCommitCount,
            sentinelWriteCount: finalWalStats.sentinelWriteCount,
            writeCallCount: finalWalStats.writeCallCount,
            replaySnapshotHitCount: finalWalStats.replaySnapshotHitCount
        )

        let duration = durationMs(clock.now - started)
        let health = WALCompactionHealthSummary(
            verifyPassed: verifyPassed,
            reopenFrameCountMatches: reopenFrameCountMatches,
            expectedFrameCount: UInt64(workload.totalWrites),
            reopenedFrameCount: reopenedFrameCount,
            notes: healthNotes
        )

        return WALCompactionWorkloadResult(
            workload: workload,
            durationMs: duration,
            putLatencyMs: WALCompactionLatencySummary.from(samples: putLatenciesMs),
            stageLatencyMs: WALCompactionLatencySummary.from(samples: stageLatenciesMs),
            commitLatencyMs: WALCompactionLatencySummary.from(samples: commitLatenciesMs),
            autoCommitPutLatencyMs: WALCompactionLatencySummary.from(samples: autoCommitPutLatenciesMs),
            pressure: pressure,
            growth: growth,
            finalLogicalBytes: finalSizes.logical,
            finalAllocatedBytes: finalSizes.allocated,
            reopenLatencyMs: WALCompactionLatencySummary.from(samples: reopenSamplesMs),
            health: health
        )
    }

    private static func documentText(for index: Int, workload: WALCompactionWorkload) -> String {
        let base = [
            "Wax WAL compaction benchmark workload.",
            "This sentence drives deterministic text indexing.",
            "Commit latency and checkpoint behavior are sampled.",
            "Pending bytes and wrap frequency are tracked over time.",
            "Reopen timing is measured after write-heavy runs."
        ]

        var parts: [String] = []
        parts.reserveCapacity(12)
        parts.append("workload=\(workload.name)")
        parts.append("mode=\(workload.mode.rawValue)")
        parts.append("doc=\(index)")
        parts.append(contentsOf: base)
        if workload.mode == .hybrid {
            parts.append("hybrid embedding dimensions=\(workload.vectorDimensions)")
        }
        parts.append("marker=\(index % 17)")

        let text = parts.joined(separator: " ")
        if text.utf8.count >= workload.payloadBytes {
            let clipped = text.prefix(workload.payloadBytes)
            return String(clipped)
        }
        let padCount = workload.payloadBytes - text.utf8.count
        if padCount == 0 { return text }
        return text + " " + String(repeating: "x", count: padCount - 1)
    }

    private static func fileSizes(at url: URL) throws -> (logical: UInt64, allocated: UInt64) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let logical = UInt64(max(0, values.fileSize ?? 0))
        let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        let allocated = UInt64(max(0, allocatedValue))
        return (logical: logical, allocated: allocated)
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
