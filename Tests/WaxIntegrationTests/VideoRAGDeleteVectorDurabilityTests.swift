import Foundation
import Testing
@testable import Wax
import WaxVectorSearch

// Byte-level proof that VideoRAG delete and re-ingest (supersede) remove segment
// vectors from the committed vector index. Before the fix, VideoRAGOrchestrator only
// deleted frames and left ghost keyframe vectors searchable.

private struct DeleteDurabilityVideoEmbedder: MultimodalEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 8
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "DeleteDurabilityVideo",
        dimensions: 8,
        normalized: true
    )

    func embed(text: String) async throws -> [Float] {
        let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
        let raw = (0..<dimensions).map { i in Float((hash &+ i) % 97) / 97.0 }
        return VectorMath.normalizeL2(raw)
    }

    func embed(image: CGImage) async throws -> [Float] {
        let hash = (image.width &* 31) &+ image.height
        let raw = (0..<dimensions).map { i in Float((hash &+ i &* 13) % 101) / 101.0 }
        return VectorMath.normalizeL2(raw)
    }
}

private func videoDeleteCommittedVecFrameIds(from bytes: Data) throws -> [UInt64] {
    let decoded = try VectorSerializer.decodeVecSegment(from: bytes)
    guard case .metal(_, _, let frameIds) = decoded else {
        throw WaxError.io("unexpected vec payload (expected .metal/.flat decode)")
    }
    return frameIds
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
        embedder: DeleteDurabilityVideoEmbedder()
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

        let beforeBytes = try await wax.readCommittedVecIndexBytes()
        #expect(beforeBytes != nil, "setup: committed vec must exist after flush")
        let beforeIds = try videoDeleteCommittedVecFrameIds(from: beforeBytes!)
        for segmentId in segmentIds {
            #expect(beforeIds.contains(segmentId), "setup: segment vector must be committed")
        }

        try await orchestrator.delete(videoID: VideoID(source: .file, id: "delete-me"))

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil, "committed vec bytes must be non-nil after delete")
        let afterIds = try videoDeleteCommittedVecFrameIds(from: afterBytes!)
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

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil)
        let afterIds = try videoDeleteCommittedVecFrameIds(from: afterBytes!)
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
