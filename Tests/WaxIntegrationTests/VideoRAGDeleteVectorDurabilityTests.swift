import CoreGraphics
import Foundation
import Testing
@testable import Wax
import WaxTestSupport
import WaxVectorSearch
import WaxCore
import WaxTextSearch

// Proof that VideoRAG delete and re-ingest (supersede) remove segment
// vectors from the committed vector index. Before the fix, VideoRAGOrchestrator only
// deleted frames and left ghost keyframe vectors searchable.

/// The committed vector index's frame ids; `nil` when the store has none.
private func videoDeleteCommittedVecFrameIds(of wax: Wax) async throws -> [UInt64]? {
    guard let committed = try await wax.readCommittedVectors() else { return nil }
    #expect(try await wax.committedVectorFrameIds() == Set(committed.frameIds))
    return committed.frameIds
}

private func videoDeleteRootId(wax: Wax, superseded: Bool) async throws -> UInt64 {
    try #require(await wax.frameMetas().first {
        $0.kind == VideoFrameKind.root.rawValue && (($0.supersededBy != nil) == superseded)
    }?.id)
}

private func videoDeleteSegmentIds(wax: Wax, underRoot rootId: UInt64) async throws -> [UInt64] {
    await wax.frameMetas()
        .filter { $0.kind == VideoFrameKind.segment.rawValue && $0.parentId == rootId }
        .map(\.id)
        .sorted()
}

private func videoDeleteMakeOrchestrator(storeURL: URL) async throws -> VideoRAGOrchestrator {
    var config = VideoRAGConfig.default
    config.segmentDurationSeconds = 60
    config.segmentOverlapSeconds = 0
    config.maxSegmentsPerVideo = 1
    config.vectorEnginePreference = .cpuOnly
    return try await VideoRAGOrchestrator(
        storeURL: storeURL,
        config: config,
        embedder: ByteSumMultimodalEmbedder(model: "DeleteDurabilityVideo")
    )
}

@Test
func videoRAGDeleteRemovesSegmentVectorsFromCommittedVecBytes() async throws {
    try await TempFiles.withTempFile { storeURL in
        let mp4URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4URL, width: 32, height: 32, frameCount: 2, fps: 2)

        let orchestrator = try await videoDeleteMakeOrchestrator(storeURL: storeURL)
        try await orchestrator.ingest(files: [VideoFile(id: "delete-me", url: mp4URL, captureDate: nil)])
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let rootId = try await videoDeleteRootId(wax: wax, superseded: false)
        let segmentIds = try await videoDeleteSegmentIds(wax: wax, underRoot: rootId)
        #expect(!segmentIds.isEmpty, "setup: ingest must produce segment frames")

        let beforeVec = try await videoDeleteCommittedVecFrameIds(of: wax)
        #expect(beforeVec != nil, "setup: committed vec must exist after flush")
        let beforeIds = try #require(beforeVec)
        for segmentId in segmentIds {
            #expect(beforeIds.contains(segmentId), "setup: segment vector must be committed")
        }

        try await orchestrator.delete(videoID: VideoID(source: .file, id: "delete-me"))

        let afterVec = try await videoDeleteCommittedVecFrameIds(of: wax)
        #expect(afterVec != nil, "committed vec index must exist after delete")
        let afterIds = try #require(afterVec)
        for segmentId in segmentIds {
            #expect(
                !afterIds.contains(segmentId),
                "deleted video segment vector still present in committed vec after delete"
            )
        }

        try await orchestrator.flush()
    }
}

@Test
func videoRAGReingestRemovesSupersededSegmentVectorsFromCommittedVecBytes() async throws {
    try await TempFiles.withTempFile { storeURL in
        let mp4URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4URL, width: 32, height: 32, frameCount: 2, fps: 2)

        let orchestrator = try await videoDeleteMakeOrchestrator(storeURL: storeURL)
        let file = VideoFile(id: "reingest-me", url: mp4URL, captureDate: nil)

        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let oldRootId = try await videoDeleteRootId(wax: wax, superseded: false)
        let oldSegmentIds = try await videoDeleteSegmentIds(wax: wax, underRoot: oldRootId)
        #expect(!oldSegmentIds.isEmpty, "setup: ingest must produce segment frames")

        // Re-ingesting the same video supersedes the previous root and its segments.
        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()

        let newRootId = try await videoDeleteRootId(wax: wax, superseded: false)
        #expect(newRootId != oldRootId)
        let newSegmentIds = try await videoDeleteSegmentIds(wax: wax, underRoot: newRootId)
        #expect(!newSegmentIds.isEmpty)
        #expect(Set(newSegmentIds).isDisjoint(with: oldSegmentIds))

        let afterVec = try await videoDeleteCommittedVecFrameIds(of: wax)
        #expect(afterVec != nil)
        let afterIds = try #require(afterVec)
        for segmentId in oldSegmentIds {
            #expect(
                !afterIds.contains(segmentId),
                "superseded video segment vector still present in committed vec after re-ingest"
            )
        }
        for segmentId in newSegmentIds {
            #expect(afterIds.contains(segmentId))
        }

        try await orchestrator.flush()
    }
}

@Test
func videoRAGRebuildSweepsLegacyGhostVectorForSupersededTree() async throws {
    try await TempFiles.withTempFile { storeURL in
        let mp4URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4URL, width: 32, height: 32, frameCount: 2, fps: 2)

        let orchestrator = try await videoDeleteMakeOrchestrator(storeURL: storeURL)
        let file = VideoFile(id: "legacy-ghost", url: mp4URL, captureDate: nil)

        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let oldRootId = try await videoDeleteRootId(wax: wax, superseded: false)
        let oldSegmentIds = try await videoDeleteSegmentIds(wax: wax, underRoot: oldRootId)
        let ghostSegmentId = try #require(oldSegmentIds.first, "setup: ingest must produce segment frames")

        // Re-ingest supersedes the tree; current cleanup removes its vectors.
        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()
        let newRootId = try await videoDeleteRootId(wax: wax, superseded: false)
        let newSegmentIds = try await videoDeleteSegmentIds(wax: wax, underRoot: newRootId)

        // Simulate a store written before vector cleanup existed: a superseded
        // segment vector is still present in the committed index.
        try await wax.putEmbedding(frameId: ghostSegmentId, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        try await orchestrator.flush()
        let legacyVec = try await videoDeleteCommittedVecFrameIds(of: wax)
        #expect(
            (legacyVec ?? []).contains(ghostSegmentId),
            "setup: injected legacy ghost must be committed"
        )

        // The next index rebuild sweeps retired-tree vectors out of the committed index.
        try await orchestrator.ingest(files: [VideoFile(id: "sweep-trigger", url: mp4URL, captureDate: nil)])
        try await orchestrator.flush()

        let sweptVec = try await videoDeleteCommittedVecFrameIds(of: wax)
        #expect(sweptVec != nil)
        let sweptIds = try #require(sweptVec)
        #expect(!sweptIds.contains(ghostSegmentId), "legacy ghost vector survived the retired-tree sweep")
        for segmentId in newSegmentIds {
            #expect(sweptIds.contains(segmentId), "current segment vectors must survive the sweep")
        }

        try await orchestrator.flush()
    }
}
