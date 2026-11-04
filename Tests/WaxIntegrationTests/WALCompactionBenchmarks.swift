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
        guard let largeHybrid = results.first(where: { $0.workload.name == "large_hybrid_10k" }) else {
            XCTFail("missing large_hybrid_10k workload result")
            return
        }
        guard let sustainedHybrid = results.first(where: { $0.workload.name == "sustained_write_hybrid" }) else {
            XCTFail("missing sustained_write_hybrid workload result")
            return
        }
        XCTAssertLessThanOrEqual(
            largeHybrid.commitLatencyMs.p95Ms,
            160.0,
            "large_hybrid_10k commit p95 regression: current=\(largeHybrid.commitLatencyMs.p95Ms.formatMs) budget=160.00ms"
        )
        XCTAssertLessThanOrEqual(
            largeHybrid.commitLatencyMs.p99Ms,
            200.0,
            "large_hybrid_10k commit p99 regression: current=\(largeHybrid.commitLatencyMs.p99Ms.formatMs) budget=200.00ms"
        )
        XCTAssertLessThanOrEqual(
            sustainedHybrid.commitLatencyMs.p95Ms,
            90.0,
            "sustained_write_hybrid commit p95 regression: current=\(sustainedHybrid.commitLatencyMs.p95Ms.formatMs) budget=90.00ms"
        )
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

        print(
            "🧪 WAL proactive guardrail: "
                + "disabled put p95=\(disabled.putLatencyMs.p95Ms.formatMs) "
                + "enabled put p95=\(enabled.putLatencyMs.p95Ms.formatMs) "
                + "disabled auto-commit put p95=\(disabled.autoCommitPutLatencyMs.p95Ms.formatMs) "
                + "enabled auto-commit put p95=\(enabled.autoCommitPutLatencyMs.p95Ms.formatMs) "
                + "disabled pending p95=\(disabled.pressure.pendingBytesP95) "
                + "enabled pending p95=\(enabled.pressure.pendingBytesP95)"
        )

        // Percentile guardrails: avoid large tail regressions while pressure improves.
        XCTAssertLessThanOrEqual(
            enabled.putLatencyMs.p95Ms,
            disabled.putLatencyMs.p95Ms * 1.20 + 2.0
        )
        // This workload has no explicit commit schedule, so commitLatencyMs only
        // measures the single final commit and is not a proactive-compaction metric.
        // Explicit commit latency is covered by testWALCompactionWorkloadMatrix().
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

        // Exclude first-open compilation and filesystem cache warm-up from the
        // comparison; the guardrail is about steady-state reopen cost.
        // Warm and measure the two modes in the same time window. Shared CI
        // runners can otherwise make the second mode look slower when host
        // load changes between the two measurement batches.
        for _ in 0..<2 {
            _ = try await measureReopenLatency(
                at: disabledURL,
                iterations: 1,
                options: WaxOptions(walReplayStateSnapshotEnabled: false)
            )
            _ = try await measureReopenLatency(
                at: enabledURL,
                iterations: 1,
                options: WaxOptions(walReplayStateSnapshotEnabled: true)
            )
        }

        // One stalled open on a loaded host used to decide this check: a p95/p99 of 8 samples is
        // in effect the slowest sample, and the arms were compared unpaired, disabled always
        // first. So each round reopens both copies back to back (alternating which goes first),
        // and the guardrail compares the median over rounds of the paired difference
        // `enabled - disabled`: load shared by a round cancels, and up to four outlying rounds
        // are outvoted.
        var disabledSamples: [Double] = []
        var enabledSamples: [Double] = []
        var enabledSnapshotHits = 0
        for round in 0..<Self.replayGuardrailRounds {
            let order: [Bool] = round.isMultiple(of: 2) ? [false, true] : [true, false]
            for snapshotEnabled in order {
                let sample = try await measureReopenLatency(
                    at: snapshotEnabled ? enabledURL : disabledURL,
                    iterations: 1,
                    options: WaxOptions(walReplayStateSnapshotEnabled: snapshotEnabled)
                )
                if snapshotEnabled {
                    enabledSamples.append(sample.summary.meanMs)
                    enabledSnapshotHits += sample.snapshotHits
                } else {
                    disabledSamples.append(sample.summary.meanMs)
                }
            }
        }

        let pairedIncreases: [Double] = zip(disabledSamples, enabledSamples).map { disabled, enabled in
            enabled - disabled
        }
        let disabledMedian: Double = disabledSamples.sorted()[disabledSamples.count / 2]
        let medianIncrease: Double = pairedIncreases.sorted()[pairedIncreases.count / 2]
        // A snapshot hit skips both the WAL replay scan and the scan of the file tail for the
        // newest footer, which together are most of a full reopen of this store (debug build:
        // about 74 ms against 375 ms). Requiring at least half the reopen time back fails when
        // either skip is lost.
        let increaseBudget: Double = -0.5 * disabledMedian

        print(
            "🧪 WAL replay snapshot guardrail (\(Self.replayGuardrailRounds) paired rounds): "
                + "median increase=\(medianIncrease.formatMs) (budget \(increaseBudget.formatMs)) "
                + "disabled=\(disabledSamples.map(\.formatMs)) "
                + "enabled=\(enabledSamples.map(\.formatMs)) "
                + "snapshot_hits=\(enabledSnapshotHits)"
        )

        // Snapshot hits do not depend on timing, so every enabled reopen must hit.
        XCTAssertEqual(enabledSnapshotHits, Self.replayGuardrailRounds)
        XCTAssertLessThanOrEqual(
            medianIncrease,
            increaseBudget,
            "snapshot reopen must take at most half the full-replay reopen time"
        )
    }

    /// Odd, so the median is one round's value; nine tolerate four outlying rounds.
    private static let replayGuardrailRounds = 9

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
            let elapsedMs = WALCompactionHarness.durationMs(clock.now - start)
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
