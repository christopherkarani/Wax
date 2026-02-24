#if canImport(XCTest)
import Foundation
import XCTest
@testable import Wax
import WaxCore

final class WALCompactionBenchmarks: XCTestCase {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_WAL_COMPACTION"] == "1"
    }

    private var guardrailsEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_WAL_GUARDRAILS"] == "1"
    }

    private var replayGuardrailsEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_WAL_REOPEN_GUARDRAILS"] == "1"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard isEnabled else {
            throw XCTSkip("Set WAX_BENCHMARK_WAL_COMPACTION=1 to run WAL compaction benchmark matrix.")
        }
    }

    func testWALCompactionWorkloadMatrix() async throws {
        let config = WALCompactionBenchmarkConfig.current()
        let workloads = WALCompactionWorkload.matrix(scale: config.scale)
        var results: [WALCompactionWorkloadResult] = []
        results.reserveCapacity(workloads.count)

        for workload in workloads {
            print("🧪 WAL workload start: \(workload.name) writes=\(workload.totalWrites) mode=\(workload.mode.rawValue) wal=\(workload.walSize)")
            let result = try await WALCompactionHarness.run(
                workload: workload,
                sampleEveryWrites: config.sampleEveryWrites,
                reopenIterations: config.reopenIterations
            )
            results.append(result)
            print(
                """
                🧪 WAL workload done: \(workload.name)
                   commit p50=\(result.commitLatencyMs.p50Ms.formatMs) p95=\(result.commitLatencyMs.p95Ms.formatMs) p99=\(result.commitLatencyMs.p99Ms.formatMs)
                   put p95=\(result.putLatencyMs.p95Ms.formatMs) autoCommitEvents=\(result.pressure.autoCommitCount) checkpoints=\(result.pressure.checkpointCount)
                   final logical=\(result.finalLogicalBytes) allocated=\(result.finalAllocatedBytes) reopen p95=\(result.reopenLatencyMs.p95Ms.formatMs)
                """
            )
        }

        let report = WALCompactionBenchmarkReport(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            scale: config.scale.rawValue,
            workloads: results
        )
        try WALCompactionReportWriter.write(report, to: config.outputPath)
        print("🧪 WAL compaction baseline JSON written to \(config.outputPath)")

        XCTAssertEqual(results.count, workloads.count)
    }

    func testProactivePressureGuardrails() async throws {
        guard guardrailsEnabled else {
            throw XCTSkip("Set WAX_BENCHMARK_WAL_GUARDRAILS=1 to run proactive WAL percentile guardrails.")
        }

        let workload = WALCompactionWorkload(
            name: "guardrail_sustained_text",
            mode: .textOnly,
            totalWrites: 12_000,
            commitEveryWrites: nil,
            walSize: 512 * 1024,
            payloadBytes: 256,
            vectorDimensions: 0
        )

        let disabled = try await WALCompactionHarness.run(
            workload: workload,
            sampleEveryWrites: 250,
            reopenIterations: 5,
            waxOptions: WaxOptions(
                walProactiveCommitThresholdPercent: nil,
                walProactiveCommitMaxWalSizeBytes: nil
            )
        )
        let enabled = try await WALCompactionHarness.run(
            workload: workload,
            sampleEveryWrites: 250,
            reopenIterations: 5,
            waxOptions: WaxOptions()
        )

        XCTAssertGreaterThan(disabled.autoCommitPutLatencyMs.samples, 0)
        XCTAssertGreaterThan(enabled.autoCommitPutLatencyMs.samples, 0)

        // Percentile guardrails: avoid large tail regressions while pressure improves.
        XCTAssertLessThanOrEqual(
            enabled.putLatencyMs.p95Ms,
            disabled.putLatencyMs.p95Ms * 1.20 + 2.0
        )
        XCTAssertLessThanOrEqual(
            enabled.commitLatencyMs.p95Ms,
            disabled.commitLatencyMs.p95Ms * 1.20 + 5.0
        )
        XCTAssertLessThanOrEqual(
            enabled.autoCommitPutLatencyMs.p95Ms,
            disabled.autoCommitPutLatencyMs.p95Ms * 1.15 + 10.0
        )

        XCTAssertLessThan(
            enabled.pressure.pendingBytesP95,
            disabled.pressure.pendingBytesP95
        )
    }

    func testReplayStateSnapshotGuardrails() async throws {
        guard replayGuardrailsEnabled else {
            throw XCTSkip("Set WAX_BENCHMARK_WAL_REOPEN_GUARDRAILS=1 to run replay snapshot guardrails.")
        }

        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wal-replay-snapshot-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        let disabledURL = baseURL.deletingPathExtension().appendingPathExtension("disabled.wax")
        let enabledURL = baseURL.deletingPathExtension().appendingPathExtension("enabled.wax")
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: disabledURL)
            try? FileManager.default.removeItem(at: enabledURL)
        }

        try await prepareReplaySnapshotStressFile(at: baseURL)
        try FileManager.default.copyItem(at: baseURL, to: disabledURL)
        try FileManager.default.copyItem(at: baseURL, to: enabledURL)

        let disabled = try await measureReopenLatency(
            at: disabledURL,
            iterations: 8,
            options: WaxOptions(walReplayStateSnapshotEnabled: false)
        )
        let enabled = try await measureReopenLatency(
            at: enabledURL,
            iterations: 8,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )

        XCTAssertGreaterThanOrEqual(enabled.snapshotHits, 1)
        // CI variance for reopen benchmarks can be high on shared runners.
        // Keep a mild relative-improvement signal, but allow modest jitter.
        XCTAssertLessThanOrEqual(
            enabled.summary.p95Ms,
            disabled.summary.p95Ms * 0.95 + 20.0
        )
        XCTAssertLessThanOrEqual(
            enabled.summary.p99Ms,
            disabled.summary.p99Ms * 0.95 + 30.0
        )
    }

    private func prepareReplaySnapshotStressFile(at url: URL) async throws {
        let wax = try await Wax.create(
            at: url,
            walSize: 4 * 1024 * 1024,
            options: WaxOptions(
                walProactiveCommitThresholdPercent: nil,
                walReplayStateSnapshotEnabled: true
            )
        )

        _ = try await wax.put(
            Data("seed".utf8),
            options: FrameMetaSubset(searchText: "seed")
        )
        try await wax.commit()

        for index in 0..<20_000 {
            _ = try await wax.put(
                Data("replay-snapshot-\(index)".utf8),
                options: FrameMetaSubset(searchText: "replay-snapshot-\(index)")
            )
        }
        try await wax.commit()
        try await wax.close()

        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            XCTFail("expected valid header pages")
            return
        }

        let selectedOffset: UInt64 = selected.pageIndex == 0 ? 0 : Constants.headerPageSize
        try file.writeAll(Data(repeating: 0, count: Int(Constants.headerPageSize)), at: selectedOffset)
        try file.fsync()
    }

    private func measureReopenLatency(
        at url: URL,
        iterations: Int,
        options: WaxOptions
    ) async throws -> (summary: WALCompactionLatencySummary, snapshotHits: Int) {
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        var snapshotHits = 0

        for _ in 0..<iterations {
            let start = clock.now
            let wax = try await Wax.open(at: url, options: options)
            let elapsedMs = Double((clock.now - start).components.attoseconds) / 1_000_000_000_000_000
            samples.append(elapsedMs)
            let stats = await wax.walStats()
            if stats.replaySnapshotHitCount > 0 {
                snapshotHits += 1
            }
            try await wax.close()
        }

        return (WALCompactionLatencySummary.from(samples: samples), snapshotHits)
    }
}

private extension Double {
    var formatMs: String {
        String(format: "%.2fms", self)
    }
}
#endif
