import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    package func accessStatsSnapshot() async -> [UInt64: FrameAccessStats] {
        await accessStatsManager.snapshot()
    }

    /// Records an explicit use of a frame (get/promote). Search and recall rank
    /// against the stored snapshot but do not mutate engagement.
    package func recordAccess(frameId: UInt64) async {
        let nowMs = config.rag.deterministicNowMs ?? nowProvider()
        await recordEngagementsIfEnabled(frameIds: [frameId], nowMs: nowMs)
    }

    package func recordImpression(frameId: UInt64) async {
        await recordImpressions(frameIds: [frameId])
    }

    package func recordImpressions(frameIds: [UInt64]) async {
        let nowMs = config.rag.deterministicNowMs ?? nowProvider()
        await recordImpressionsIfEnabled(frameIds: frameIds, nowMs: nowMs)
    }

    package func seedAccessStats(frameId: UInt64, from stats: FrameAccessStats) async {
        guard config.enableAccessStatsScoring else { return }
        await accessStatsManager.seedStats(stats, for: frameId)
    }

    private func recordAccessesIfEnabled(frameIds: [UInt64], nowMs: Int64) async {
        await recordEngagementsIfEnabled(frameIds: frameIds, nowMs: nowMs)
    }

    private func recordEngagementsIfEnabled(frameIds: [UInt64], nowMs: Int64) async {
        guard config.enableAccessStatsScoring, !frameIds.isEmpty else { return }
        await accessStatsManager.recordAccesses(frameIds: frameIds, nowMs: nowMs)
    }

    private func recordImpressionsIfEnabled(frameIds: [UInt64], nowMs: Int64) async {
        guard config.enableAccessStatsScoring, !frameIds.isEmpty else { return }
        await accessStatsManager.recordImpressions(frameIds: frameIds, nowMs: nowMs)
    }

    /// Internal only because of the file split; called from `init`.
    func loadPersistedAccessStatsIfNeeded() async throws {
        guard let latest = await wax.latestCommittedActiveSystemFrameMeta(
            kind: Self.accessStatsFrameKind,
            fallbackMetadataKey: Self.accessStatsMarkerKey,
            fallbackMetadataValue: Self.accessStatsMarkerValue
        ) else {
            return
        }

        let payload = try await wax.frameContent(frameId: latest.id)
        do {
            let imported = try JSONDecoder().decode([FrameAccessStats].self, from: payload)
            await accessStatsManager.importStats(imported)
            accessStatsFrameId = latest.id
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "access stats import",
                fallback: "starting with empty access stats"
            )
        }
    }

    /// Internal only because of the file split; call only while holding `flushMutex` (see `flush()`).
    func persistAccessStatsIfNeeded() async throws {
        guard let snapshot = await accessStatsManager.exportStatsSnapshotIfDirty() else {
            return
        }
        if let hold = accessStatsPersistenceHoldForTesting {
            try await Task.sleep(for: hold)
        }
        let exported = snapshot.stats
        guard !exported.isEmpty else {
            _ = await accessStatsManager.markPersisted(ifRevision: snapshot.revision)
            return
        }
        let payload = try JSONEncoder().encode(exported)

        var metadata = Metadata()
        metadata.entries[Self.accessStatsMarkerKey] = Self.accessStatsMarkerValue
        let frameId = try await session.put(
            payload,
            options: FrameMetaSubset(
                kind: Self.accessStatsFrameKind,
                labels: [Self.accessStatsLabel],
                role: .system,
                metadata: metadata
            )
        )
        let previousFrameId = accessStatsFrameId
        // Update the tracked frame ID before superseding so that if supersede throws,
        // the next flush will still attempt to supersede this frame rather than
        // the pre-supersede frame, preventing orphaned stats frames from accumulating.
        accessStatsFrameId = frameId
        if let previous = previousFrameId, previous != frameId {
            do {
                try await wax.supersede(supersededId: previous, supersedingId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "access stats supersede",
                    fallback: "previous stats frame may remain active until next flush"
                )
            }
        }
        // A get/promote may have recorded newer accesses while the WAL writes
        // above awaited. Only acknowledge the revision we actually persisted;
        // a newer revision remains dirty for the next flush.
        _ = await accessStatsManager.markPersisted(ifRevision: snapshot.revision)
    }
}
