import Foundation
import Testing
import Wax

@Test
func rewriteLiveSetDropsNonLivePayloadsAndPreservesFrameState() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
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
func rewriteLiveSetRespectsDestinationOverwriteGuard() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
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
            keepLatestCandidates: 2
        )

        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        let report = try await orchestrator.runScheduledLiveSetMaintenanceNow()

        #expect(report.outcome == .rewriteSucceeded)
        #expect(report.rollbackPerformed == false)
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
        let clock = ContinuousClock()
        let started = clock.now
        try await orchestrator.flush()
        let flushMs = durationMs(clock.now - started)

        #expect(flushMs < 1_000)

        let report = await waitForScheduledReport(orchestrator, timeoutMs: 20_000)
        #expect(report != nil)
        #expect(report?.outcome == .rewriteSucceeded)
        #expect(report?.triggeredByFlush == true)

        try await orchestrator.close()
    }
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

private func durationMs(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
}
