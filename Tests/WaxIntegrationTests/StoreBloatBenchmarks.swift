#if canImport(XCTest)
import Foundation
import XCTest
@testable import Wax
@testable import WaxCore

final class StoreBloatBenchmarks: XCTestCase {
    private struct Metrics: Codable, Sendable {
        let beforeLogicalBytes: UInt64
        let afterLogicalBytes: UInt64
        let beforeAllocatedBytes: UInt64
        let afterAllocatedBytes: UInt64
        let deadPayloadBytesBefore: UInt64
        let deadPayloadBytesAfter: UInt64
        let deadPayloadFractionBefore: Double
        let deadPayloadFractionAfter: Double
        let tocBytesBefore: Int
        let tocBytesAfter: Int
        let frameCountBefore: UInt64
        let frameCountAfter: UInt64
        let segmentCatalogEntryCountBefore: Int
        let segmentCatalogEntryCountAfter: Int
    }

    func testCloseTimeLiveSetRewriteMetrics() async throws {
        guard ProcessInfo.processInfo.environment["WAX_BENCHMARK_STORE_BLOAT"] == "1" else {
            throw XCTSkip("Set WAX_BENCHMARK_STORE_BLOAT=1 to run store-bloat benchmarks.")
        }

        let outputPath = ProcessInfo.processInfo.environment["WAX_BENCHMARK_STORE_BLOAT_OUTPUT"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tasks")
            .appendingPathComponent("store-bloat-after.json")
            .path

        try await TempFiles.withTempFile { sourceURL in
            let maintenanceDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: maintenanceDir) }

            try await seedDeadPayloadStore(at: sourceURL)
            let before = try collectMetrics(at: sourceURL)

            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            config.liveSetRewriteSchedule = LiveSetRewriteSchedule(
                enabled: true,
                checkEveryFlushes: 1,
                minDeadPayloadBytes: 64 * 1024,
                minDeadPayloadFraction: 0.05,
                minimumCompactionGainBytes: 0,
                minimumIdleMs: 0,
                minIntervalMs: 0,
                verifyDeep: false,
                destinationDirectory: maintenanceDir,
                keepLatestCandidates: 2,
                promoteValidatedCandidateOnClose: true
            )

            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            try await orchestrator.close()

            let after = try collectMetrics(at: sourceURL)
            let metrics = Metrics(
                beforeLogicalBytes: before.logicalBytes,
                afterLogicalBytes: after.logicalBytes,
                beforeAllocatedBytes: before.allocatedBytes,
                afterAllocatedBytes: after.allocatedBytes,
                deadPayloadBytesBefore: before.deadPayloadBytes,
                deadPayloadBytesAfter: after.deadPayloadBytes,
                deadPayloadFractionBefore: before.deadPayloadFraction,
                deadPayloadFractionAfter: after.deadPayloadFraction,
                tocBytesBefore: before.tocBytes,
                tocBytesAfter: after.tocBytes,
                frameCountBefore: before.frameCount,
                frameCountAfter: after.frameCount,
                segmentCatalogEntryCountBefore: before.segmentCatalogEntryCount,
                segmentCatalogEntryCountAfter: after.segmentCatalogEntryCount
            )

            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metrics).write(to: outputURL, options: .atomic)
        }
    }

    private func collectMetrics(at url: URL) throws -> (
        logicalBytes: UInt64,
        allocatedBytes: UInt64,
        deadPayloadBytes: UInt64,
        deadPayloadFraction: Double,
        tocBytes: Int,
        frameCount: UInt64,
        segmentCatalogEntryCount: Int
    ) {
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

        return (
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            deadPayloadBytes: deadPayloadBytes,
            deadPayloadFraction: deadPayloadFraction,
            tocBytes: footerSlice.tocBytes.count,
            frameCount: UInt64(toc.frames.count),
            segmentCatalogEntryCount: toc.segmentCatalog.entries.count
        )
    }

    private func seedDeadPayloadStore(at url: URL) async throws {
        let wax = try await Wax.create(at: url)
        let largeDeadPayload = Data(repeating: 0x41, count: 192 * 1024)

        let oldFrame = try await wax.put(
            largeDeadPayload,
            options: FrameMetaSubset(searchText: "old scheduled payload")
        )
        let replacementFrame = try await wax.put(
            Data("active replacement".utf8),
            options: FrameMetaSubset(searchText: "active replacement")
        )
        try await wax.supersede(supersededId: oldFrame, supersedingId: replacementFrame)

        let deletedFrame = try await wax.put(
            largeDeadPayload,
            options: FrameMetaSubset(searchText: "to delete")
        )
        try await wax.delete(frameId: deletedFrame)

        try await wax.commit()
        try await wax.close()
    }
}
#endif
