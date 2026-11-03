import Foundation
import WaxCore

extension AgentBrokerService {
    func memoryHealth() async throws -> AgentBrokerValue {
        let documents = try await longTermMemory.corpusSourceDocuments()
        let accessStats = await longTermMemory.accessStatsSnapshot()
        let facts = try? await longTermMemory.facts(limit: Self.maxGraphLimit)
        let report = BrokerMemoryInsights.healthReport(
            documents: documents,
            accessStats: accessStats,
            facts: facts,
            settings: retentionSettings
        )
        let sessionDisk = currentSessionDiskStats()
        return .object([
            "total_documents": .from(report.totalDocuments),
            "typed_counts": .object(report.typedCounts.mapValues { .from($0) }),
            "expired_frame_ids": .array(report.expiredFrameIds.map(AgentBrokerValue.from)),
            "stale_frame_ids": .array(report.staleFrameIds.map(AgentBrokerValue.from)),
            "low_hit_frame_ids": .array(report.lowHitFrameIds.map(AgentBrokerValue.from)),
            "quarantine_candidate_ids": .array(report.quarantineCandidateIds.map(AgentBrokerValue.from)),
            "reclaimable_session_ids": .array(sessionDisk.reclaimableSessionIDs.map { .string($0.uuidString) }),
            "duplicate_pairs": .array(report.duplicatePairs.map { pair in
                .object([
                    "left_frame_id": .from(pair.leftFrameId),
                    "right_frame_id": .from(pair.rightFrameId),
                    "similarity": .double(Double(pair.similarity)),
                ])
            }),
            "contradictions": .array(report.contradictionSummaries.map(AgentBrokerValue.string)),
            "unsuperseded_duplicate_decisions": .array(report.unsupersededDuplicateDecisions.map { pair in
                .object([
                    "left_frame_id": .from(pair.leftFrameId),
                    "right_frame_id": .from(pair.rightFrameId),
                    "similarity": .double(Double(pair.similarity)),
                ])
            }),
            "display_text": .string("Health: \(report.totalDocuments) docs, \(report.duplicatePairs.count) duplicate pairs, \(report.contradictionSummaries.count) contradiction signals."),
        ])
    }

    private func currentSessionDiskStats() -> SessionDiskStats {
        let nowMs = BrokerClock.nowMs()
        if let cached = cachedSessionDisk, nowMs - cached.atMs < Self.sessionDiskCacheTTLMs {
            return cached.stats
        }
        let manifests: [BrokerSessionManifest]
        let listError: String?
        do {
            manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
            listError = nil
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "stats session manifest listing",
                fallback: "session counts reported as unavailable"
            )
            manifests = []
            listError = error.localizedDescription
        }
        var stats = SessionReclaim.diskStats(
            rootURL: sessionRootURL,
            manifests: manifests,
            liveIDs: Set(activeSessions.keys),
            nowMs: nowMs
        )
        stats.listError = listError
        // A failed listing is not cached: the next stats call retries.
        if listError == nil {
            cachedSessionDisk = (nowMs, stats)
        }
        return stats
    }

    func stats(_ command: BrokerCommand.Stats = .init(sessionID: nil)) async throws -> AgentBrokerValue {
        let requestedSessionID = command.sessionID
        let stats = await longTermMemory.runtimeStats()
        let activeSessionIDs = activeSessions.keys.sorted { $0.uuidString < $1.uuidString }
        let diskBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: stats.storeURL.path),
                  let size = attrs[.size] as? NSNumber
            else { return 0 }
            return size.uint64Value
        }()
        let sessionStats: MemoryOrchestrator.SessionRuntimeStats
        if let requestedSessionID {
            if let session = activeSessions[requestedSessionID] {
                sessionStats = try await session.memory.sessionRuntimeStats(sessionId: requestedSessionID)
            } else {
                sessionStats = .init(
                    active: false,
                    sessionId: requestedSessionID,
                    sessionFrameCount: 0,
                    sessionTokenEstimate: 0,
                    pendingFramesStoreWide: stats.pendingFrames,
                    countsIncludePending: false
                )
            }
        } else {
            sessionStats = .init(
                active: !activeSessionIDs.isEmpty,
                sessionId: nil,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: stats.pendingFrames,
                countsIncludePending: false
            )
        }

        let embedder: AgentBrokerValue = {
            guard let identity = stats.embedderIdentity else { return .null }
            return .object([
                "provider": .from(identity.provider),
                "model": .from(identity.model),
                "dimensions": .from(identity.dimensions),
                "normalized": .from(identity.normalized),
            ])
        }()
        let sessionDisk = currentSessionDiskStats()
        let reviewQueueDepth = await reviewQueueDepth()

        return .object([
            "frameCount": .from(stats.frameCount),
            "pendingFrames": .from(stats.pendingFrames),
            "framesWithoutVectors": .from(stats.framesWithoutVectors),
            "review_queue_depth": .from(reviewQueueDepth),
            "generation": .from(stats.generation),
            "diskBytes": .from(diskBytes),
            "storePath": .string(stats.storeURL.path),
            "vectorSearchEnabled": .from(stats.vectorSearchEnabled),
            "embeddingStatus": .string(stats.embeddingStatus.wireName),
            "embeddingStatusReason": .from(stats.embeddingStatus.wireReason),
            "queryEmbeddingAvailable": .from(
                stats.vectorSearchEnabled && stats.queryEmbedderReady && !stats.queryEmbeddingCircuitOpen
            ),
            "queryEmbeddingCircuitOpen": .from(stats.queryEmbeddingCircuitOpen),
            "features": .object([
                "structuredMemoryEnabled": .from(stats.structuredMemoryEnabled),
                "accessStatsScoringEnabled": .from(stats.accessStatsScoringEnabled),
            ]),
            "embedder": embedder,
            "wal": .object([
                "walSize": .from(stats.wal.walSize),
                "writePos": .from(stats.wal.writePos),
                "checkpointPos": .from(stats.wal.checkpointPos),
                "pendingBytes": .from(stats.wal.pendingBytes),
                "committedSeq": .from(stats.wal.committedSeq),
                "lastSeq": .from(stats.wal.lastSeq),
                "wrapCount": .from(stats.wal.wrapCount),
                "checkpointCount": .from(stats.wal.checkpointCount),
                "replayTruncationCount": .from(stats.wal.replayTruncationCount),
            ]),
            "session": .object([
                "active": .from(sessionStats.active),
                "session_id": .from(sessionStats.sessionId?.uuidString),
                "activeSessionCount": .from(activeSessionIDs.count),
                "activeSessionIds": .array(activeSessionIDs.map { .string($0.uuidString) }),
                "sessionFrameCount": .from(sessionStats.sessionFrameCount),
                "sessionTokenEstimate": .from(sessionStats.sessionTokenEstimate),
                "pendingFramesStoreWide": .from(sessionStats.pendingFramesStoreWide),
                "countsIncludePending": .from(sessionStats.countsIncludePending),
            ]),
            "sessions": sessionDisk.asBrokerValue(),
        ])
    }

    /// Live unreviewed durable decisions/constraints awaiting human review.
    /// `remember(reviewed: true)` is the mark that clears a frame from this count.
    package static func isReviewQueueFrame(_ metadata: [String: String]) -> Bool {
        guard let type = metadata[MemoryMetadataKeys.type].flatMap(MemoryType.init(rawValue:)) else {
            return false
        }
        guard type == .decision || type == .constraint else { return false }
        return metadata[MemoryMetadataKeys.reviewed]?.lowercased() != "true"
    }

    private func reviewQueueDepth() async -> Int {
        let metas = await longTermMemory.wax.frameMetas()
        return metas.filter { meta in
            guard meta.status == .active, meta.supersededBy == nil, meta.role == .document else {
                return false
            }
            return Self.isReviewQueueFrame(meta.metadata?.entries ?? [:])
        }.count
    }
}
