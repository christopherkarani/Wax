import Foundation
import Testing

/// Source-level locks that Phase 5 shared helpers replaced private clones.
@Test func phase5SharedHelpersHaveNoPrivateClones() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let photo = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    let video = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    let memory = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Orchestrator/MemoryOrchestrator.swift"),
        encoding: .utf8
    )
    let unified = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/UnifiedSearch/UnifiedSearch.swift"),
        encoding: .utf8
    )
    let session = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/WaxSession.swift"),
        encoding: .utf8
    )
    let fileLock = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxCore/IO/FileLock.swift"),
        encoding: .utf8
    )
    let storeProbe = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/StoreLockProbe.swift"),
        encoding: .utf8
    )
    let searchRequest = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/UnifiedSearch/SearchRequest.swift"),
        encoding: .utf8
    )

    #expect(searchRequest.contains("fromClosedDateRange"))
    #expect(photo.contains("SearchTimeRange.fromClosedDateRange"))
    #expect(video.contains("SearchTimeRange.fromClosedDateRange"))
    #expect(!photo.contains("private static func toWaxTimeRange"))
    #expect(!video.contains("private static func toWaxTimeRange"))

    #expect(session.contains("func sweepRetiredVectors"))
    #expect(photo.contains("session.sweepRetiredVectors"))
    #expect(video.contains("session.sweepRetiredVectors"))
    #expect(!photo.contains("private func sweepRetiredVectors"))
    #expect(!video.contains("private func sweepRetiredVectors"))

    #expect(memory.contains("SearchExplanationDeduper.dedupedExplanations"))
    #expect(unified.contains("SearchExplanationDeduper.dedupedExplanations"))
    #expect(!memory.contains("private func dedupedExplanations"))
    #expect(!unified.contains("private static func dedupedExplanations"))

    #expect(fileLock.contains("DurationFormatting.format"))
    #expect(storeProbe.contains("DurationFormatting.format"))
    #expect(!fileLock.contains("private static func formatDuration"))
    #expect(!storeProbe.contains("private static func formatDuration"))

    #expect(session.contains("putBatchWithOptionalTimestamps"))
}
