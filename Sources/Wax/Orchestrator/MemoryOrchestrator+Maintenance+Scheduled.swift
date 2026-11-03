import Foundation
import WaxCore

package extension MemoryOrchestrator {
    func runScheduledLiveSetMaintenanceNow() async throws -> ScheduledLiveSetMaintenanceReport {
        if let queuedTask = scheduledLiveSetMaintenanceTask {
            await queuedTask.value
        }

        let report = try await runScheduledLiveSetMaintenanceIfNeeded(
            flushCount: flushCount,
            force: true,
            triggeredByFlush: false
        ) ?? ScheduledLiveSetMaintenanceReport(
            outcome: .disabled,
            triggeredByFlush: false,
            flushCount: flushCount,
            deadPayloadBytes: 0,
            totalPayloadBytes: 0,
            deadPayloadFraction: 0,
            candidateURL: nil,
            rewriteReport: nil,
            rollbackPerformed: false,
            notes: ["live-set rewrite schedule is disabled"]
        )
        lastScheduledLiveSetMaintenanceReport = report
        return report
    }

    func runScheduledLiveSetMaintenanceIfNeeded(
        flushCount: UInt64,
        force: Bool,
        triggeredByFlush: Bool
    ) async throws -> ScheduledLiveSetMaintenanceReport? {
        let schedule = config.liveSetRewriteSchedule
        guard schedule.enabled else {
            if force {
                return ScheduledLiveSetMaintenanceReport(
                    outcome: .disabled,
                    triggeredByFlush: triggeredByFlush,
                    flushCount: flushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["live-set rewrite schedule is disabled"]
                )
            }
            return nil
        }

        let cadence = UInt64(max(1, schedule.checkEveryFlushes))
        if !force, flushCount % cadence != 0 {
            return ScheduledLiveSetMaintenanceReport(
                outcome: .cadenceSkipped,
                triggeredByFlush: triggeredByFlush,
                flushCount: flushCount,
                deadPayloadBytes: 0,
                totalPayloadBytes: 0,
                deadPayloadFraction: 0,
                candidateURL: nil,
                rewriteReport: nil,
                rollbackPerformed: false,
                notes: ["cadence gate skipped for flush \(flushCount); every \(cadence) flushes"]
            )
        }

        let now = ContinuousClock.now
        if !force, schedule.minIntervalMs > 0, let lastRun = scheduledLiveSetMaintenanceLastCompletedAt {
            let nextAllowed = lastRun.advanced(by: .milliseconds(max(0, schedule.minIntervalMs)))
            if now < nextAllowed {
                return ScheduledLiveSetMaintenanceReport(
                    outcome: .cooldownSkipped,
                    triggeredByFlush: triggeredByFlush,
                    flushCount: flushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["minimum interval gate skipped; waiting for cooldown"]
                )
            }
        }

        if !force, schedule.minimumIdleMs > 0 {
            let idleEligibleAt = lastWriteActivityAt.advanced(by: .milliseconds(max(0, schedule.minimumIdleMs)))
            if now < idleEligibleAt {
                return ScheduledLiveSetMaintenanceReport(
                    outcome: .idleSkipped,
                    triggeredByFlush: triggeredByFlush,
                    flushCount: flushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["minimum idle gate skipped; recent writes detected"]
                )
            }
        }

        let sourceURL = (await wax.fileURL()).standardizedFileURL
        let payloadBytes = await wax.committedPayloadLivenessBytes()
        let totalPayloadBytes = payloadBytes.totalPayloadBytes
        let deadPayloadBytes = payloadBytes.deadPayloadBytes
        let deadPayloadFraction = totalPayloadBytes == 0
            ? 0
            : Double(deadPayloadBytes) / Double(totalPayloadBytes)

        let clampedFractionThreshold = min(1, max(0, schedule.minDeadPayloadFraction))
        let meetsBytesThreshold = deadPayloadBytes >= schedule.minDeadPayloadBytes
        let meetsFractionThreshold = deadPayloadFraction >= clampedFractionThreshold

        guard meetsBytesThreshold || meetsFractionThreshold else {
            return ScheduledLiveSetMaintenanceReport(
                outcome: .belowThreshold,
                triggeredByFlush: triggeredByFlush,
                flushCount: flushCount,
                deadPayloadBytes: deadPayloadBytes,
                totalPayloadBytes: totalPayloadBytes,
                deadPayloadFraction: deadPayloadFraction,
                candidateURL: nil,
                rewriteReport: nil,
                rollbackPerformed: false,
                notes: [
                    "below thresholds bytes=\(deadPayloadBytes)/\(schedule.minDeadPayloadBytes)",
                    "fraction=\(deadPayloadFraction)/\(clampedFractionThreshold)"
                ]
            )
        }

        let fileManager = FileManager.default
        let destinationDirectory = (schedule.destinationDirectory ?? sourceURL.deletingLastPathComponent())
            .standardizedFileURL
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let candidateURL = destinationDirectory
            .appendingPathComponent("\(baseName)-liveset-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        var attemptedRewrite = false
        defer {
            if attemptedRewrite {
                scheduledLiveSetMaintenanceLastCompletedAt = .now
            }
        }

        let rewriteReport: LiveSetRewriteReport
        do {
            attemptedRewrite = true
            rewriteReport = try await rewriteLiveSet(
                to: candidateURL,
                options: .init(
                    overwriteDestination: true,
                    dropNonLivePayloads: true,
                    verifyDeep: schedule.verifyDeep
                )
            )
        } catch {
            try? fileManager.removeItem(at: candidateURL)
            return ScheduledLiveSetMaintenanceReport(
                outcome: .rewriteFailed,
                triggeredByFlush: triggeredByFlush,
                flushCount: flushCount,
                deadPayloadBytes: deadPayloadBytes,
                totalPayloadBytes: totalPayloadBytes,
                deadPayloadFraction: deadPayloadFraction,
                candidateURL: candidateURL,
                rewriteReport: nil,
                rollbackPerformed: true,
                notes: ["rewrite failed: \(error)"]
            )
        }

        var validationNotes: [String] = []
        var validationFailed = false
        let compactionGain = rewriteReport.logicalBytesBefore > rewriteReport.logicalBytesAfter
            ? rewriteReport.logicalBytesBefore - rewriteReport.logicalBytesAfter
            : 0

        if compactionGain < schedule.minimumCompactionGainBytes {
            validationFailed = true
            validationNotes.append(
                "compaction gain below threshold: gained \(compactionGain), required \(schedule.minimumCompactionGainBytes)"
            )
        }

        do {
            let rewritten = try await Wax.open(at: candidateURL)
            let rewrittenStats = await rewritten.stats()
            if rewrittenStats.frameCount != UInt64(rewriteReport.frameCount) {
                validationFailed = true
                validationNotes.append(
                    "frame count mismatch: expected \(rewriteReport.frameCount), got \(rewrittenStats.frameCount)"
                )
            }
            try await rewritten.verify(deep: schedule.verifyDeep)
            try await rewritten.close()
        } catch {
            validationFailed = true
            validationNotes.append("verification failed: \(error)")
        }

        if validationFailed {
            try? fileManager.removeItem(at: candidateURL)
            return ScheduledLiveSetMaintenanceReport(
                outcome: .validationFailedRolledBack,
                triggeredByFlush: triggeredByFlush,
                flushCount: flushCount,
                deadPayloadBytes: deadPayloadBytes,
                totalPayloadBytes: totalPayloadBytes,
                deadPayloadFraction: deadPayloadFraction,
                candidateURL: candidateURL,
                rewriteReport: rewriteReport,
                rollbackPerformed: true,
                notes: validationNotes
            )
        }

        try Self.pruneScheduledRewriteCandidates(
            in: destinationDirectory,
            baseName: baseName,
            keepLatest: schedule.keepLatestCandidates
        )

        return ScheduledLiveSetMaintenanceReport(
            outcome: .rewriteSucceeded,
            triggeredByFlush: triggeredByFlush,
            flushCount: flushCount,
            deadPayloadBytes: deadPayloadBytes,
            totalPayloadBytes: totalPayloadBytes,
            deadPayloadFraction: deadPayloadFraction,
            candidateURL: candidateURL,
            rewriteReport: rewriteReport,
            rollbackPerformed: false,
            notes: ["rewrite candidate validated", "compaction gain bytes: \(compactionGain)"]
        )
    }

    private static func pruneScheduledRewriteCandidates(
        in directory: URL,
        baseName: String,
        keepLatest: Int
    ) throws {
        let keepCount = max(0, keepLatest)
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let prefix = "\(baseName)-liveset-"
        let candidates = contents.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(".wax")
        }
        guard candidates.count > keepCount else { return }

        let sorted = candidates.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        for stale in sorted.dropFirst(keepCount) {
            try? fileManager.removeItem(at: stale)
        }
    }
}
