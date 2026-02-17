import Foundation
import XCTest
@testable import Wax

final class WALCompactionBenchmarks: XCTestCase {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_WAL_COMPACTION"] == "1"
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
}

private extension Double {
    var formatMs: String {
        String(format: "%.2fms", self)
    }
}
