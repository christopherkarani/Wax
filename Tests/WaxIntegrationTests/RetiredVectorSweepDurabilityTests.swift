#if canImport(ImageIO)
import CoreGraphics
import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

@Suite("RetiredVectorSweepDurabilityTests")
struct RetiredVectorSweepDurabilityTests {
    @Test
    func photoRAGRebuildCommitSurvivesAbruptTerminationWithoutFlush() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-sweep-kill-photo-\(UUID().uuidString).png")
            try photoSweepTinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let ghostId = try await seedPhotoLegacyGhost(
                storeURL: storeURL,
                imageURL: imageURL,
                assetID: "legacy-ghost-kill"
            )

            try runRebuildChildAndTerminate(storeURL: storeURL, kind: "photo")

            let wax = try await Wax.open(at: storeURL)
            let bytes = try await wax.readCommittedVecIndexBytes()
            #expect(bytes != nil, "committed vec bytes must exist after abrupt rebuild termination")
            let ids = try sweepCommittedVecFrameIds(from: bytes!)
            #expect(
                !ids.contains(ghostId),
                "retired photo frame \(ghostId) resurrected after rebuild without flush/close"
            )
            try await wax.close()
        }
    }

    @Test
    func photoRAGRebuildThrowsWhenPostSweepCommitFailsAndLeavesGhostCommitted() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-sweep-fault-photo-\(UUID().uuidString).png")
            try photoSweepTinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let ghostId = try await seedPhotoLegacyGhost(
                storeURL: storeURL,
                imageURL: imageURL,
                assetID: "legacy-ghost-fault"
            )

            RetiredVectorSweepFaultInjection.enableCommitFailure(for: storeURL)
            defer { RetiredVectorSweepFaultInjection.disableCommitFailure(for: storeURL) }

            do {
                let orchestrator = try await makePhotoSweepOrchestrator(storeURL: storeURL)
                await orchestrator.session.close()
                try await orchestrator.wax.close()
                Issue.record("photo open/rebuild succeeded despite injected post-sweep commit failure")
            } catch {
                let message = String(describing: error)
                #expect(
                    message.contains("injected retired-vector sweep commit failure"),
                    "open/rebuild must throw the injected commit failure, got: \(message)"
                )
            }

            let wax = try await Wax.open(at: storeURL)
            let bytes = try await wax.readCommittedVecIndexBytes()
            #expect(bytes != nil)
            let ids = try sweepCommittedVecFrameIds(from: bytes!)
            #expect(
                ids.contains(ghostId),
                "commit-failure path must not report a successful sweep while leaving ghosts committed"
            )
            try await wax.close()
        }
    }

    #if canImport(AVFoundation)
    @Test
    func videoRAGRebuildCommitSurvivesAbruptTerminationWithoutFlush() async throws {
        try await TempFiles.withTempFile { storeURL in
            let mp4URL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: mp4URL) }
            try await VideoRAGTestVideoGenerator.writeTinyMP4(
                to: mp4URL,
                width: 32,
                height: 32,
                frameCount: 2,
                fps: 2
            )

            let ghostId = try await seedVideoLegacyGhost(storeURL: storeURL, mp4URL: mp4URL)

            try runRebuildChildAndTerminate(storeURL: storeURL, kind: "video")

            let wax = try await Wax.open(at: storeURL)
            let bytes = try await wax.readCommittedVecIndexBytes()
            #expect(bytes != nil, "committed vec bytes must exist after abrupt rebuild termination")
            let ids = try sweepCommittedVecFrameIds(from: bytes!)
            #expect(
                !ids.contains(ghostId),
                "retired video frame \(ghostId) resurrected after rebuild without flush/close"
            )
            try await wax.close()
        }
    }

    @Test
    func videoRAGRebuildThrowsWhenPostSweepCommitFailsAndLeavesGhostCommitted() async throws {
        try await TempFiles.withTempFile { storeURL in
            let mp4URL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: mp4URL) }
            try await VideoRAGTestVideoGenerator.writeTinyMP4(
                to: mp4URL,
                width: 32,
                height: 32,
                frameCount: 2,
                fps: 2
            )

            let ghostId = try await seedVideoLegacyGhost(storeURL: storeURL, mp4URL: mp4URL)

            RetiredVectorSweepFaultInjection.enableCommitFailure(for: storeURL)
            defer { RetiredVectorSweepFaultInjection.disableCommitFailure(for: storeURL) }

            do {
                let orchestrator = try await makeVideoSweepOrchestrator(storeURL: storeURL)
                await orchestrator.session.close()
                try await orchestrator.wax.close()
                Issue.record("video open/rebuild succeeded despite injected post-sweep commit failure")
            } catch {
                let message = String(describing: error)
                #expect(
                    message.contains("injected retired-vector sweep commit failure"),
                    "open/rebuild must throw the injected commit failure, got: \(message)"
                )
            }

            let wax = try await Wax.open(at: storeURL)
            let bytes = try await wax.readCommittedVecIndexBytes()
            #expect(bytes != nil)
            let ids = try sweepCommittedVecFrameIds(from: bytes!)
            #expect(
                ids.contains(ghostId),
                "commit-failure path must not report a successful sweep while leaving ghosts committed"
            )
            try await wax.close()
        }
    }

    @Test
    func videoRebuildAfterCrashedDeleteDoesNotPersistGhostsAndSurvivesKillAfterRepair() async throws {
        try await TempFiles.withTempFile { storeURL in
            let mp4URL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: mp4URL) }
            try await VideoRAGTestVideoGenerator.writeTinyMP4(
                to: mp4URL,
                width: 32,
                height: 32,
                frameCount: 2,
                fps: 2
            )

            let ghostId = try await seedVideoLegacyGhost(storeURL: storeURL, mp4URL: mp4URL)
            let liveRootId = try await liveVideoRootId(storeURL: storeURL)

            try runPendingMutationChild(storeURL: storeURL, kind: "video-pending-delete")
            try runRebuildChildAndKillAfterCommit(storeURL: storeURL, kind: "video")

            let wax = try await Wax.open(at: storeURL)
            let bytes = try await wax.readCommittedVecIndexBytes()
            #expect(bytes != nil, "repair commit must persist a vec index")
            let ids = try sweepCommittedVecFrameIds(from: bytes!)
            #expect(
                !ids.contains(ghostId),
                "historical retired video frame \(ghostId) survived repair after crash-during-delete"
            )
            #expect(
                !ids.contains(liveRootId),
                "pending-deleted live video root \(liveRootId) persisted as a ghost vector after repair"
            )
            let liveRoots = liveVideoRoots(from: await wax.frameMetas())
            #expect(liveRoots.isEmpty, "pending deletes must be committed; live roots=\(liveRoots)")
            try await wax.close()
        }
    }

    @Test
    func videoRebuildAfterCrashedIngestThenRetryKeepsSingleLiveRoot() async throws {
        try await TempFiles.withTempFile { storeURL in
            let mp4URL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: mp4URL) }
            try await VideoRAGTestVideoGenerator.writeTinyMP4(
                to: mp4URL,
                width: 32,
                height: 32,
                frameCount: 2,
                fps: 2
            )

            _ = try await seedVideoLegacyGhost(storeURL: storeURL, mp4URL: mp4URL)

            try runPendingMutationChild(storeURL: storeURL, kind: "video-pending-ingest")
            try runRebuildChildAndKillAfterCommit(storeURL: storeURL, kind: "video")

            let orchestrator = try await makeVideoSweepOrchestrator(storeURL: storeURL)
            let file = VideoFile(id: "legacy-ghost-kill", url: mp4URL, captureDate: nil)
            try await orchestrator.ingest(files: [file])
            try await orchestrator.flush()

            let wax = await orchestrator.wax
            let liveRoots = liveVideoRoots(from: await wax.frameMetas())
            #expect(
                liveRoots.count == 1,
                "crash-during-ingest + retry produced \(liveRoots.count) live roots: \(liveRoots)"
            )
            await orchestrator.session.close()
            try await orchestrator.wax.close()
        }
    }
    #endif

    @Test
    func photoRebuildAfterCrashedDeleteDoesNotPersistGhostsAndSurvivesKillAfterRepair() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-sweep-pending-delete-\(UUID().uuidString).png")
            try photoSweepTinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let ghostId = try await seedPhotoLegacyGhost(
                storeURL: storeURL,
                imageURL: imageURL,
                assetID: "pending-delete-asset"
            )
            let liveRootId = try await livePhotoRootId(storeURL: storeURL, assetID: "pending-delete-asset")

            try runPendingMutationChild(storeURL: storeURL, kind: "photo-pending-delete")
            try runRebuildChildAndKillAfterCommit(storeURL: storeURL, kind: "photo")

            let wax = try await Wax.open(at: storeURL)
            let bytes = try await wax.readCommittedVecIndexBytes()
            #expect(bytes != nil, "repair commit must persist a vec index")
            let ids = try sweepCommittedVecFrameIds(from: bytes!)
            #expect(
                !ids.contains(ghostId),
                "historical retired photo frame \(ghostId) survived repair after crash-during-delete"
            )
            #expect(
                !ids.contains(liveRootId),
                "pending-deleted live photo root \(liveRootId) persisted as a ghost vector after repair"
            )
            let liveRoots = livePhotoRoots(from: await wax.frameMetas(), assetID: "pending-delete-asset")
            #expect(liveRoots.isEmpty, "pending deletes must be committed; live roots=\(liveRoots)")
            try await wax.close()
        }
    }

    @Test
    func photoRebuildAfterCrashedIngestThenRetryKeepsSingleLiveRoot() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-sweep-pending-ingest-\(UUID().uuidString).png")
            try photoSweepTinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            _ = try await seedPhotoLegacyGhost(
                storeURL: storeURL,
                imageURL: imageURL,
                assetID: "pending-ingest-asset"
            )

            try runPendingMutationChild(storeURL: storeURL, kind: "photo-pending-ingest")
            try runRebuildChildAndKillAfterCommit(storeURL: storeURL, kind: "photo")

            let orchestrator = try await makePhotoSweepOrchestrator(storeURL: storeURL)
            let file = PhotoFile(
                id: "pending-ingest-asset",
                url: imageURL,
                captureDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try await orchestrator.ingest(files: [file])
            try await orchestrator.flush()

            let wax = await orchestrator.wax
            let liveRoots = livePhotoRoots(from: await wax.frameMetas(), assetID: "pending-ingest-asset")
            #expect(
                liveRoots.count == 1,
                "crash-during-ingest + retry produced \(liveRoots.count) live roots: \(liveRoots)"
            )
            await orchestrator.session.close()
            try await orchestrator.wax.close()
        }
    }

    @Test
    func photoRAGSweepStoreUsesPublicFourMiBWal() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-sweep-wal-size-\(UUID().uuidString).png")
            try photoSweepTinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            _ = try await seedPhotoLegacyGhost(
                storeURL: storeURL,
                imageURL: imageURL,
                assetID: "wal-size-asset"
            )

            let wax = try await Wax.open(at: storeURL)
            let stats = await wax.walStats()
            #expect(stats.walSize == Memory.Config.defaultWalSizeBytes)
            #expect(Memory.Config.defaultWalSizeBytes == 4 * 1024 * 1024)
            try await wax.close()
        }
    }

    @Test
    func photoRAGSecondOpenDoesNotCommitWhenRetiredVectorsAlreadySwept() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-sweep-second-open-\(UUID().uuidString).png")
            try photoSweepTinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let ghostId = try await seedPhotoLegacyGhost(
                storeURL: storeURL,
                imageURL: imageURL,
                assetID: "second-open-asset"
            )

            let repaired = try await makePhotoSweepOrchestrator(storeURL: storeURL)
            let generationAfterRepair = (await repaired.wax.stats()).generation
            let repairedIds = try sweepCommittedVecFrameIds(
                from: try #require(await repaired.wax.readCommittedVecIndexBytes())
            )
            #expect(!repairedIds.contains(ghostId), "first open must commit the sweep")
            await repaired.session.close()
            try await repaired.wax.close()

            let second = try await makePhotoSweepOrchestrator(storeURL: storeURL)
            let generationOnSecondOpen = (await second.wax.stats()).generation
            #expect(
                generationOnSecondOpen == generationAfterRepair,
                "second open with already-swept history must not repair-commit (gen \(generationAfterRepair) → \(generationOnSecondOpen))"
            )
            let secondIds = try sweepCommittedVecFrameIds(
                from: try #require(await second.wax.readCommittedVecIndexBytes())
            )
            #expect(!secondIds.contains(ghostId))
            await second.session.close()
            try await second.wax.close()
        }
    }

    @Test
    func photoRAGRebuildSurvivesSIGKILLDuringRepairCommitAfterTocWrite() async throws {
        try await assertPhotoRepairKillDuringCommit(
            checkpoint: "after_toc_write_before_footer",
            assetID: "kill-during-toc"
        )
    }

    @Test
    func photoRAGRebuildSurvivesSIGKILLDuringRepairCommitAfterFooterWrite() async throws {
        try await assertPhotoRepairKillDuringCommit(
            checkpoint: "after_footer_write_before_fsync",
            assetID: "kill-during-footer"
        )
    }

    @Test
    func photoRAGRebuildThrowsWhenCommitFaultsAfterTocWriteAndReopenIsConsistent() async throws {
        try await assertPhotoRepairCommitIOFault(
            point: .afterTocWriteBeforeFooter,
            assetID: "fault-toc"
        )
    }

    @Test
    func photoRAGRebuildThrowsWhenCommitFaultsAfterFooterWriteAndReopenIsConsistent() async throws {
        try await assertPhotoRepairCommitIOFault(
            point: .afterFooterWriteBeforeFsync,
            assetID: "fault-footer"
        )
    }
}

// MARK: - Seed / inspect

private let photoSweepTinyPNGData = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII="
)!

private func sweepCommittedVecFrameIds(from bytes: Data) throws -> [UInt64] {
    let decoded = try VectorSerializer.decodeVecSegment(from: bytes)
    guard case .metal(_, _, let frameIds) = decoded else {
        throw WaxError.io("unexpected vec payload (expected .metal/.flat decode)")
    }
    return frameIds
}

private func makePhotoSweepOrchestrator(storeURL: URL) async throws -> PhotoRAGOrchestrator {
    var config = PhotoRAGConfig.default
    config.includeThumbnailsInContext = false
    config.includeRegionCropsInContext = false
    config.enableOCR = false
    config.enableRegionEmbeddings = false
    config.vectorEnginePreference = .cpuOnly
    return try await PhotoRAGOrchestrator(
        storeURL: storeURL,
        config: config,
        embedder: DeterministicMultimodalEmbedder(),
        walSizeBytes: Memory.Config.defaultWalSizeBytes
    )
}

private func photoSweepRootId(wax: Wax, assetID: String, superseded: Bool) async throws -> UInt64 {
    try #require(await wax.frameMetas().first {
        $0.kind == PhotoFrameKind.root.rawValue
            && $0.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == assetID
            && (($0.supersededBy != nil) == superseded)
    }?.id)
}

private func livePhotoRoots(from metas: [FrameMeta], assetID: String) -> [UInt64] {
    metas.compactMap { meta in
        guard meta.kind == PhotoFrameKind.root.rawValue,
              meta.status != .deleted,
              meta.supersededBy == nil,
              meta.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == assetID
        else { return nil }
        return meta.id
    }
}

private func livePhotoRootId(storeURL: URL, assetID: String) async throws -> UInt64 {
    let wax = try await Wax.open(at: storeURL)
    let rootId = try #require(livePhotoRoots(from: await wax.frameMetas(), assetID: assetID).first)
    try await wax.close()
    return rootId
}

private func seedPhotoLegacyGhost(storeURL: URL, imageURL: URL, assetID: String) async throws -> UInt64 {
    let orchestrator = try await makePhotoSweepOrchestrator(storeURL: storeURL)
    let file = PhotoFile(id: assetID, url: imageURL, captureDate: Date(timeIntervalSince1970: 1_700_000_000))
    try await orchestrator.ingest(files: [file])
    try await orchestrator.flush()

    let wax = await orchestrator.wax
    let oldRootId = try await photoSweepRootId(wax: wax, assetID: assetID, superseded: false)

    try await orchestrator.ingest(files: [file])
    try await orchestrator.flush()

    try await wax.putEmbedding(frameId: oldRootId, vector: [1, 0, 0, 0])
    try await orchestrator.flush()

    let legacyBytes = try await wax.readCommittedVecIndexBytes()
    #expect(
        try sweepCommittedVecFrameIds(from: legacyBytes!).contains(oldRootId),
        "setup: injected legacy ghost must be committed"
    )

    await orchestrator.session.close()
    try await orchestrator.wax.close()
    return oldRootId
}

#if canImport(AVFoundation)
private struct SweepDurabilityVideoEmbedder: CGImageEmbeddingProvider {
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

private func makeVideoSweepOrchestrator(storeURL: URL) async throws -> VideoRAGOrchestrator {
    var config = VideoRAGConfig.default
    config.segmentDurationSeconds = 60
    config.segmentOverlapSeconds = 0
    config.maxSegmentsPerVideo = 1
    config.vectorEnginePreference = .cpuOnly
    return try await VideoRAGOrchestrator(
        storeURL: storeURL,
        config: config,
        embedder: SweepDurabilityVideoEmbedder(),
        walSizeBytes: Memory.Config.defaultWalSizeBytes
    )
}

private func seedVideoLegacyGhost(storeURL: URL, mp4URL: URL) async throws -> UInt64 {
    let orchestrator = try await makeVideoSweepOrchestrator(storeURL: storeURL)
    let file = VideoFile(id: "legacy-ghost-kill", url: mp4URL, captureDate: nil)
    try await orchestrator.ingest(files: [file])
    try await orchestrator.flush()

    let wax = await orchestrator.wax
    let oldRootId = try #require(await wax.frameMetas().first {
        $0.kind == VideoFrameKind.root.rawValue && $0.supersededBy == nil
    }?.id)
    let ghostSegmentId = try #require(
        await wax.frameMetas().first {
            $0.kind == VideoFrameKind.segment.rawValue && $0.parentId == oldRootId
        }?.id,
        "setup: ingest must produce segment frames"
    )

    try await orchestrator.ingest(files: [file])
    try await orchestrator.flush()

    try await wax.putEmbedding(frameId: ghostSegmentId, vector: [1, 0, 0, 0, 0, 0, 0, 0])
    try await orchestrator.flush()

    let legacyBytes = try await wax.readCommittedVecIndexBytes()
    #expect(
        try sweepCommittedVecFrameIds(from: legacyBytes!).contains(ghostSegmentId),
        "setup: injected legacy ghost must be committed"
    )

    await orchestrator.session.close()
    try await orchestrator.wax.close()
    return ghostSegmentId
}

private func liveVideoRoots(from metas: [FrameMeta]) -> [UInt64] {
    metas.compactMap { meta in
        guard meta.kind == VideoFrameKind.root.rawValue,
              meta.status != .deleted,
              meta.supersededBy == nil
        else { return nil }
        return meta.id
    }
}

private func liveVideoRootId(storeURL: URL) async throws -> UInt64 {
    let wax = try await Wax.open(at: storeURL)
    let rootId = try #require(liveVideoRoots(from: await wax.frameMetas()).first)
    try await wax.close()
    return rootId
}
#endif

// MARK: - Child process

private enum SweepHarnessError: Error, CustomStringConvertible {
    case notFound([URL])
    case childFailed(status: Int32, stdout: String, stderr: String)

    var description: String {
        switch self {
        case .notFound(let candidates):
            return "Could not find WaxRetiredVectorSweepHarness. Tried:\n\(candidates.map(\.path).joined(separator: "\n"))"
        case .childFailed(let status, let stdout, let stderr):
            return "child failed status=\(status)\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        }
    }
}

private func assertPhotoRepairKillDuringCommit(checkpoint: String, assetID: String) async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-sweep-kill-\(assetID)-\(UUID().uuidString).png")
        try photoSweepTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let ghostId = try await seedPhotoLegacyGhost(
            storeURL: storeURL,
            imageURL: imageURL,
            assetID: assetID
        )

        try runRebuildChildAndKillDuringCommit(
            storeURL: storeURL,
            kind: "photo",
            checkpoint: checkpoint
        )

        let wax = try await Wax.open(at: storeURL)
        let bytes = try await wax.readCommittedVecIndexBytes()
        #expect(bytes != nil, "store must reopen after SIGKILL during repair commit")
        let ids = try sweepCommittedVecFrameIds(from: bytes!)
        let ghostPresent = ids.contains(ghostId)
        let liveRoots = livePhotoRoots(from: await wax.frameMetas(), assetID: assetID)
        #expect(
            liveRoots.count == 1,
            "repair-commit crash must not tear live roots; liveRoots=\(liveRoots)"
        )
        try await wax.close()

        let repaired = try await makePhotoSweepOrchestrator(storeURL: storeURL)
        let repairedIds = try sweepCommittedVecFrameIds(
            from: try #require(await repaired.wax.readCommittedVecIndexBytes())
        )
        #expect(
            !repairedIds.contains(ghostId),
            "successful reopen after mid-commit SIGKILL must finish repair (ghostPresentOnFirstReopen=\(ghostPresent))"
        )
        await repaired.session.close()
        try await repaired.wax.close()
    }
}

private func assertPhotoRepairCommitIOFault(
    point: CommitIOFaultInjection.Point,
    assetID: String
) async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-sweep-iofault-\(assetID)-\(UUID().uuidString).png")
        try photoSweepTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let ghostId = try await seedPhotoLegacyGhost(
            storeURL: storeURL,
            imageURL: imageURL,
            assetID: assetID
        )

        CommitIOFaultInjection.enable(point, for: storeURL)
        defer { CommitIOFaultInjection.disable(for: storeURL) }

        do {
            let orchestrator = try await makePhotoSweepOrchestrator(storeURL: storeURL)
            await orchestrator.session.close()
            try await orchestrator.wax.close()
            Issue.record("photo open/rebuild succeeded despite injected \(point.rawValue) commit fault")
        } catch {
            let message = String(describing: error)
            #expect(
                message.contains("injected commit I/O fault"),
                "open/rebuild must throw the injected I/O fault, got: \(message)"
            )
        }

        CommitIOFaultInjection.disable(for: storeURL)

        let wax = try await Wax.open(at: storeURL)
        let bytes = try await wax.readCommittedVecIndexBytes()
        #expect(bytes != nil, "torn TOC/footer must not produce an unreadable store")
        let ids = try sweepCommittedVecFrameIds(from: bytes!)
        let ghostPresent = ids.contains(ghostId)
        let liveRoots = livePhotoRoots(from: await wax.frameMetas(), assetID: assetID)
        #expect(
            liveRoots.count == 1,
            "commit I/O fault must leave a consistent pre- or post-repair TOC; liveRoots=\(liveRoots)"
        )
        try await wax.close()

        let repaired = try await makePhotoSweepOrchestrator(storeURL: storeURL)
        let repairedIds = try sweepCommittedVecFrameIds(
            from: try #require(await repaired.wax.readCommittedVecIndexBytes())
        )
        #expect(
            !repairedIds.contains(ghostId),
            "next successful open must complete repair (ghostPresentOnFaultReopen=\(ghostPresent))"
        )
        await repaired.session.close()
        try await repaired.wax.close()
    }
}

private func runRebuildChildAndKillAfterCommit(storeURL: URL, kind: String) throws {
    let process = Process()
    process.executableURL = try sweepHarnessURL()
    var environment = ProcessInfo.processInfo.environment
    environment["WAX_RETIRED_VECTOR_SWEEP_STORE"] = storeURL.path
    environment["WAX_RETIRED_VECTOR_SWEEP_KIND"] = kind
    environment["WAX_RETIRED_VECTOR_SWEEP_CRASH_AFTER_COMMIT"] = "1"
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationReason == .uncaughtSignal, process.terminationStatus == 9 else {
        throw SweepHarnessError.childFailed(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

private func runRebuildChildAndKillDuringCommit(storeURL: URL, kind: String, checkpoint: String) throws {
    let process = Process()
    process.executableURL = try sweepHarnessURL()
    var environment = ProcessInfo.processInfo.environment
    environment["WAX_RETIRED_VECTOR_SWEEP_STORE"] = storeURL.path
    environment["WAX_RETIRED_VECTOR_SWEEP_KIND"] = kind
    environment["WAX_CRASH_INJECT_CHECKPOINT"] = checkpoint
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationReason == .uncaughtSignal, process.terminationStatus == 9 else {
        throw SweepHarnessError.childFailed(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

private func runPendingMutationChild(storeURL: URL, kind: String) throws {
    let process = Process()
    process.executableURL = try sweepHarnessURL()
    var environment = ProcessInfo.processInfo.environment
    environment["WAX_RETIRED_VECTOR_SWEEP_STORE"] = storeURL.path
    environment["WAX_RETIRED_VECTOR_SWEEP_KIND"] = kind
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0, stdout.contains("PENDING_OK") else {
        throw SweepHarnessError.childFailed(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

private func runRebuildChildAndTerminate(storeURL: URL, kind: String) throws {
    let process = Process()
    process.executableURL = try sweepHarnessURL()
    var environment = ProcessInfo.processInfo.environment
    environment["WAX_RETIRED_VECTOR_SWEEP_STORE"] = storeURL.path
    environment["WAX_RETIRED_VECTOR_SWEEP_KIND"] = kind
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0, stdout.contains("REBUILD_OK") else {
        throw SweepHarnessError.childFailed(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

private func sweepHarnessURL() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["WAX_RETIRED_VECTOR_SWEEP_HARNESS"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }

    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bundleDebugDir = Bundle.main.bundleURL.deletingLastPathComponent()
    let candidates = [
        bundleDebugDir.appendingPathComponent("WaxRetiredVectorSweepHarness"),
        packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("arm64-apple-macosx")
            .appendingPathComponent("debug")
            .appendingPathComponent("WaxRetiredVectorSweepHarness"),
        packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("WaxRetiredVectorSweepHarness"),
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw SweepHarnessError.notFound(candidates)
}
#endif
