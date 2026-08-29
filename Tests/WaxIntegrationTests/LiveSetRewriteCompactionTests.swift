import Foundation
import Testing
import Wax
import WaxCore

@Test
func rewriteLiveSetDropsNonLivePayloadsAndPreservesFrameState() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 24, overlapTokens: 4)

        do {
            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            let corpus = Array(
                repeating: "Swift concurrency uses actors and tasks for safety and predictable scheduling.",
                count: 24
            ).joined(separator: " ")
            try await orchestrator.remember(corpus)
            try await orchestrator.flush()
            try await orchestrator.close()
        }

        do {
            let wax = try await Wax.open(at: sourceURL)
            let largeDeadPayload = Data(repeating: 0x41, count: 256 * 1024)
            let oldFrame = try await wax.put(
                largeDeadPayload,
                options: FrameMetaSubset(searchText: "old release plan")
            )
            let replacementFrame = try await wax.put(
                Data("replacement frame remains active".utf8),
                options: FrameMetaSubset(searchText: "replacement release plan")
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

        let report: LiveSetRewriteReport
        do {
            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            report = try await orchestrator.rewriteLiveSet(to: destinationURL)
            try await orchestrator.close()
        }

        #expect(report.droppedPayloadFrames >= 2)
        #expect(report.logicalBytesAfter < report.logicalBytesBefore)

        let sourceWax = try await Wax.open(at: sourceURL)
        let rewrittenWax = try await Wax.open(at: destinationURL)

        let sourceMetas = await sourceWax.frameMetas()
        let rewrittenMetas = await rewrittenWax.frameMetas()
        #expect(sourceMetas.count == rewrittenMetas.count)

        for sourceMeta in sourceMetas {
            let rewrittenMeta = rewrittenMetas[Int(sourceMeta.id)]
            #expect(sourceMeta.status == rewrittenMeta.status)
            #expect(sourceMeta.supersedes == rewrittenMeta.supersedes)
            #expect(sourceMeta.supersededBy == rewrittenMeta.supersededBy)
            #expect(sourceMeta.searchText == rewrittenMeta.searchText)
            #expect(sourceMeta.metadata == rewrittenMeta.metadata)

            let sourceContent = try await sourceWax.frameContent(frameId: sourceMeta.id)
            let rewrittenContent = try await rewrittenWax.frameContent(frameId: sourceMeta.id)
            if sourceMeta.status == .active && sourceMeta.supersededBy == nil {
                #expect(sourceContent == rewrittenContent)
            } else {
                #expect(rewrittenContent.isEmpty)
            }
        }

        try await sourceWax.close()
        try await rewrittenWax.close()

        let reopened = try await MemoryOrchestrator(at: destinationURL, config: config)
        let context = try await reopened.recall(query: "actors scheduling safety")
        #expect(!context.items.isEmpty)
        try await reopened.close()
    }
}

@Test
func rewriteLiveSetWalSizeFloorsAtSessionSizeAndCapsAtSourceRing() {
    let session = Constants.sessionWalSize
    let defaultRing = Constants.defaultWalSize

    #expect(
        MemoryOrchestrator.walSizeForLiveSetRewrite(
            sourceWalSize: defaultRing,
            payloadBytes: 107_000
        ) == session
    )
    #expect(
        MemoryOrchestrator.walSizeForLiveSetRewrite(
            sourceWalSize: defaultRing,
            payloadBytes: session + 1
        ) == session + 1
    )
    #expect(
        MemoryOrchestrator.walSizeForLiveSetRewrite(
            sourceWalSize: defaultRing,
            payloadBytes: defaultRing + 1
        ) == defaultRing
    )
    #expect(
        MemoryOrchestrator.walSizeForLiveSetRewrite(
            sourceWalSize: session / 2,
            payloadBytes: 1
        ) == session / 2
    )
    #expect(
        MemoryOrchestrator.walSizeForLiveSetRewrite(
            sourceWalSize: defaultRing,
            payloadBytes: 1,
            largestFrameWalBytes: session + 1024,
            totalFrameWalBytes: session + 2048
        ) == session + 2048
    )
}

@Test
func rewriteLiveSetAccountsForLargeFrameMetadataInWalSize() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let sourceWalSize = 8 * 1024 * 1024
        let wax = try await Wax.create(at: sourceURL, walSize: UInt64(sourceWalSize))
        let largeMetadata = Metadata([
            "large": String(repeating: "m", count: 4 * 1024 * 1024)
        ])
        _ = try await wax.put(
            Data("metadata-rich frame".utf8),
            options: FrameMetaSubset(
                searchText: "metadata-rich frame",
                metadata: largeMetadata
            )
        )
        try await wax.commit()
        try await wax.close()

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        _ = try await orchestrator.rewriteLiveSet(to: destinationURL)
        try await orchestrator.close()

        let rewritten = try await Wax.open(at: destinationURL)
        let wal = await rewritten.walStats()
        #expect(wal.walSize > Constants.sessionWalSize)
        #expect(wal.walSize <= UInt64(sourceWalSize))
        try await rewritten.verify(deep: true)
        try await rewritten.close()
    }
}

@Test
func rewriteLiveSetBatchesWhenAggregateFrameWalExceedsSourceRing() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let sourceWalSize = 1 * 1024 * 1024
        let metadataValue = String(repeating: "m", count: 32 * 1024)
        let wax = try await Wax.create(at: sourceURL, walSize: UInt64(sourceWalSize))
        for index in 0..<64 {
            _ = try await wax.put(
                Data("metadata-rich frame \(index)".utf8),
                options: FrameMetaSubset(
                    searchText: "metadata-rich frame \(index)",
                    metadata: Metadata(["large": metadataValue])
                )
            )
        }
        try await wax.commit()
        try await wax.close()

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        _ = try await orchestrator.rewriteLiveSet(to: destinationURL)
        try await orchestrator.close()

        let rewritten = try await Wax.open(at: destinationURL)
        let wal = await rewritten.walStats()
        #expect(wal.walSize == UInt64(sourceWalSize))
        #expect((await rewritten.frameMetas()).count == 64)
        try await rewritten.verify(deep: true)
        try await rewritten.close()
    }
}

@Test
func rewriteLiveSetChoosesWalSizeFromPayloadNotSourceRing() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        do {
            let wax = try await Wax.create(at: sourceURL)
            for index in 0..<20 {
                _ = try await wax.put(
                    Data("small live payload \(index)".utf8),
                    options: FrameMetaSubset(searchText: "small live payload \(index)")
                )
            }
            try await wax.commit()
            let sourceWal = await wax.walStats()
            #expect(sourceWal.walSize == Constants.defaultWalSize)
            try await wax.close()
        }

        let sourceSizesBefore = try fileSizes(at: sourceURL)
        #expect(sourceSizesBefore.logical >= Constants.defaultWalSize)

        let report: LiveSetRewriteReport
        do {
            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            report = try await orchestrator.rewriteLiveSet(to: destinationURL)
            try await orchestrator.close()
        }

        let sourceSizesAfter = try fileSizes(at: sourceURL)
        #expect(sourceSizesAfter.logical == sourceSizesBefore.logical)

        let rewrittenWax = try await Wax.open(at: destinationURL)
        let destWal = await rewrittenWax.walStats()
        #expect(destWal.walSize == Constants.sessionWalSize)
        #expect(destWal.walSize >= Constants.sessionWalSize)
        #expect(destWal.walSize <= Constants.defaultWalSize)
        #expect(destWal.walSize <= 8 * 1024 * 1024)

        let destFrames = await rewrittenWax.frameMetas()
        #expect(destFrames.count == 20)
        #expect(destFrames.filter { $0.status == .active && $0.supersededBy == nil }.count == 20)
        try await rewrittenWax.verify()
        try await rewrittenWax.close()

        let destSizes = try fileSizes(at: destinationURL)
        #expect(destSizes.logical < sourceSizesBefore.logical)
        #expect(destSizes.logical < 16 * 1024 * 1024)
        #expect(report.logicalBytesAfter < report.logicalBytesBefore)
        #expect(report.frameCount == 20)
        #expect(report.activeFrameCount == 20)
    }
}

@Test
func rewriteLiveSetRespectsDestinationOverwriteGuard() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        try await orchestrator.remember("single rewrite guard frame")
        try await orchestrator.flush()

        FileManager.default.createFile(atPath: destinationURL.path, contents: Data("occupied".utf8))
        await #expect(throws: WaxError.self) {
            _ = try await orchestrator.rewriteLiveSet(to: destinationURL)
        }

        let report = try await orchestrator.rewriteLiveSet(
            to: destinationURL,
            options: .init(overwriteDestination: true, dropNonLivePayloads: true, verifyDeep: false)
        )
        #expect(report.destinationURL == destinationURL.standardizedFileURL)
        try await orchestrator.close()
    }
}

@Test
func rewriteLiveSetRefusesDirectoryAndLockedDestinationBeforePromotion() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-rewrite-safety-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination.wax")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        try await orchestrator.remember("rewrite safety frame")
        try await orchestrator.flush()

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        await #expect(throws: WaxError.self) {
            _ = try await orchestrator.rewriteLiveSet(
                to: destinationURL,
                options: .init(overwriteDestination: true)
            )
        }

        try FileManager.default.removeItem(at: destinationURL)
        FileManager.default.createFile(atPath: destinationURL.path, contents: Data("occupied".utf8))
        let lock = try FileLock.acquire(at: destinationURL, mode: .exclusive)
        await #expect(throws: WaxError.self) {
            _ = try await orchestrator.rewriteLiveSet(
                to: destinationURL,
                options: .init(overwriteDestination: true)
            )
        }
        try lock.release()
        try await orchestrator.close()
    }
}

@Test
func scheduledLiveSetRewriteCreatesValidatedCandidateWhenThresholdMet() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let maintenanceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: maintenanceDir) }

        try await seedDeadPayloadStore(at: sourceURL)

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
        let report = try await orchestrator.runScheduledLiveSetMaintenanceNow()

        #expect(report.outcome == .rewriteSucceeded)
        #expect(report.rollbackPerformed == false)
        #expect(report.deadPayloadBytes == 393_216)
        #expect(report.totalPayloadBytes == 393_234)
        #expect(report.deadPayloadFraction == Double(393_216) / Double(393_234))
        #expect(report.candidateURL != nil)
        if let candidateURL = report.candidateURL {
            #expect(FileManager.default.fileExists(atPath: candidateURL.path))
        }

        try await orchestrator.close()
    }
}

@Test
func scheduledLiveSetRewriteRollsBackCandidateWhenGainGuardFails() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let maintenanceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: maintenanceDir) }

        try await seedDeadPayloadStore(at: sourceURL)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.liveSetRewriteSchedule = LiveSetRewriteSchedule(
            enabled: true,
            checkEveryFlushes: 1,
            minDeadPayloadBytes: 64 * 1024,
            minDeadPayloadFraction: 0.05,
            minimumCompactionGainBytes: UInt64.max / 2,
            minimumIdleMs: 0,
            minIntervalMs: 0,
            verifyDeep: false,
            destinationDirectory: maintenanceDir,
            keepLatestCandidates: 2
        )

        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        let report = try await orchestrator.runScheduledLiveSetMaintenanceNow()

        #expect(report.outcome == .validationFailedRolledBack)
        #expect(report.rollbackPerformed)
        #expect(report.candidateURL != nil)
        if let candidateURL = report.candidateURL {
            #expect(FileManager.default.fileExists(atPath: candidateURL.path) == false)
        }

        try await orchestrator.close()
    }
}

@Test
func scheduledLiveSetRewriteFlushTriggerRunsDeferredFromCommitPath() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let maintenanceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: maintenanceDir) }

        try await seedDeadPayloadStore(at: sourceURL)

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
            keepLatestCandidates: 2
        )

        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        try await orchestrator.flush()

        let report = await waitForScheduledReport(orchestrator, timeoutMs: 90_000)
        // The report's trigger is the contract. Flush latency includes filesystem
        // scheduling and shared-runner load, so it is not a stable deferred-work
        // assertion.
        #expect(report != nil)
        #expect(report?.outcome == .rewriteSucceeded)
        #expect(report?.triggeredByFlush == true)

        try await orchestrator.close()
    }
}

@Test
func scheduledLiveSetRewritePromotesValidatedCandidateOnCloseAndShrinksSource() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let maintenanceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: maintenanceDir) }

        try await seedDeadPayloadStore(at: sourceURL)
        let beforeSizes = try fileSizes(at: sourceURL)

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
            keepLatestCandidates: 2
        )

        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        try await orchestrator.close()

        let afterSizes = try fileSizes(at: sourceURL)
        #expect(afterSizes.logical < beforeSizes.logical)
        #expect(afterSizes.allocated <= beforeSizes.allocated)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: maintenanceDir,
            includingPropertiesForKeys: nil
        )
        let candidates = directoryContents.filter {
            $0.lastPathComponent.hasPrefix("\(baseName)-liveset-") && $0.pathExtension == "wax"
        }
        #expect(candidates.isEmpty)

        let reopened = try await MemoryOrchestrator(at: sourceURL, config: config)
        let report = try await reopened.runScheduledLiveSetMaintenanceNow()
        #expect(report.outcome == .belowThreshold)
        #expect(report.deadPayloadBytes == 0)
        #expect(report.totalPayloadBytes == 18)
        #expect(report.deadPayloadFraction == 0)
        try await reopened.close()

        let reopenedWax = try await Wax.open(at: sourceURL)
        let frames = await reopenedWax.frameMetas()
        #expect(frames.count == 3)
        #expect(frames.filter { $0.status == .active && $0.supersededBy == nil }.count == 1)
        #expect(frames.filter { $0.status == .deleted }.count == 1)
        try await reopenedWax.close()
    }
}

@Test
func orchestratorDefaultConfigEnablesAutomaticLiveSetRewriteSchedule() {
    let schedule = OrchestratorConfig.default.liveSetRewriteSchedule
    #expect(schedule.enabled)
}

private func waitForScheduledReport(
    _ orchestrator: MemoryOrchestrator,
    timeoutMs: Int
) async -> ScheduledLiveSetMaintenanceReport? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(max(1, timeoutMs)))

    while clock.now < deadline {
        if let report = await orchestrator.scheduledLiveSetMaintenanceReport() {
            switch report.outcome {
            case .rewriteSucceeded, .rewriteFailed, .validationFailedRolledBack:
                return report
            case .disabled, .cadenceSkipped, .cooldownSkipped, .idleSkipped, .belowThreshold, .alreadyRunningSkipped:
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    return await orchestrator.scheduledLiveSetMaintenanceReport()
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

private func fileSizes(at url: URL) throws -> (logical: UInt64, allocated: UInt64) {
    let freshURL = URL(fileURLWithPath: url.path).standardizedFileURL
    let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
    let logical = UInt64(max(0, values.fileSize ?? 0))
    let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    let allocated = UInt64(max(0, allocatedValue))
    return (logical: logical, allocated: allocated)
}
