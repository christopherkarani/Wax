import Foundation
import WaxCore

extension AgentBrokerService {
    func sessionStart(_ command: BrokerCommand.SessionStart) async throws -> AgentBrokerValue {
        let explicitSessionID = command.sessionID
        let requestedAgentID = command.agentID
        let requestedRunID = command.runID
        let requestedCWD = command.cwd
        let explicitProject = command.project
        let explicitRepo = command.repo
        var inferredScope = requestedCWD.map {
            MemorySemantics.inferScopeContext(currentDirectoryPath: $0)
        } ?? MemoryScopeContext()
        if explicitProject != nil || explicitRepo != nil {
            inferredScope = MemoryScopeContext(
                cwdPath: inferredScope.cwdPath,
                repoRootPath: inferredScope.repoRootPath,
                repoName: explicitRepo ?? explicitProject ?? inferredScope.repoName,
                projectName: explicitProject ?? inferredScope.projectName
            )
        }

        let result = try await virtualSessions.start(
            explicitSessionID: explicitSessionID,
            agentID: requestedAgentID,
            runID: requestedRunID,
            inferredScope: inferredScope
        )
        if let conversationID = BrokerCommand.normalizedOrNil(command.conversationID) {
            try virtualSessions.updateLive(result.state.id) { state in
                state.manifest.conversationID = conversationID
            }
        }
        return renderSessionLifecycleResult(result)
    }

    func sessionResume(_ command: BrokerCommand.SessionResume) async throws -> AgentBrokerValue {
        let result = try await virtualSessions.resume(
            explicitSessionID: command.sessionID,
            agentID: command.agentID,
            runID: command.runID
        )
        return renderSessionLifecycleResult(result)
    }

    func sessionEnd(_ command: BrokerCommand.SessionEnd) async throws -> AgentBrokerValue {
        let requested = command.sessionID
        // Explicit session_id must rebind an active-on-disk manifest after a broker hop (C4),
        // matching remember/recall/handoff/session_close. Omitted id stays live-map only.
        if let requested {
            _ = try await virtualSessions.ensureLive(requested)
        }
        guard let target = try virtualSessions.peekEndTarget(sessionID: requested) else {
            return sessionEndPayload(.idle)
        }
        let result = try await virtualSessions.end(sessionID: target, afterFlush: makeHarvestCallback())
        return sessionEndPayload(result)
    }

    /// Atomic handoff then end for one `session_id` (C6). Idempotent when already ended.
    func sessionClose(_ command: BrokerCommand.SessionClose) async throws -> AgentBrokerValue {
        let sessionID: UUID
        if let requested = command.sessionID {
            sessionID = requested
        } else {
            guard let target = try virtualSessions.peekEndTarget(sessionID: nil) else {
                throw BrokerValidationError.invalid(
                    "session_id is required when no active session is available; call session_open with conversation_id (this host chat id). Do not invent a session_id."
                )
            }
            sessionID = target
        }
        let content = command.content
        let pendingTasks = command.pendingTasks

        if activeSessions[sessionID] == nil {
            if let status = try virtualSessions.persistedStatus(for: sessionID) {
                if status == .ended {
                    let harvest = await harvestPersistedSession(sessionID: sessionID, rememberDrained: true)
                    let payload = sessionClosePayload(
                        sessionID: sessionID,
                        ended: true,
                        alreadyEnded: true,
                        handoffFrameID: nil,
                        remainingActive: activeSessions.count,
                        harvest: harvest
                    )
                    await sweepSessionStoresAfterClose()
                    return payload
                }
            } else {
                throw BrokerSessionInactiveError.unknown(sessionID: sessionID)
            }
            // Active on disk but not live — rebind then close.
            _ = try await memory(for: sessionID)
        }

        try await validateActiveSession(sessionID)
        let project = BrokerCommand.normalizedOrNil(command.project)
            ?? writeScope(for: sessionID).projectName
        let frameId: UInt64?
        if command.recordHandoff {
            frameId = try await longTermMemory.rememberHandoff(
                content: content,
                project: project,
                pendingTasks: pendingTasks,
                sessionId: sessionID,
                commit: false
            )
            try await recordHandoff(sessionID: sessionID, content: content)
        } else {
            frameId = nil
        }
        try await longTermMemory.flush()
        let result = try await virtualSessions.end(sessionID: sessionID, afterFlush: makeHarvestCallback())
        let payload = sessionClosePayload(
            sessionID: sessionID,
            ended: result.ended,
            alreadyEnded: false,
            handoffFrameID: frameId,
            remainingActive: result.activeCount,
            harvest: result.harvest
        )
        await sweepSessionStoresAfterClose()
        return payload
    }

    /// Reclaim due ended files and harvest abandoned zombies without ending
    /// fresh expired leases (those stay rebindable until explicit maintain).
    /// Does not quarantine the long-term library — that stays operator-only
    /// via `memory_maintain`.
    private func sweepSessionStoresAfterClose() async {
        _ = await maintainSessionStores(
            apply: true,
            forceReclaim: false,
            endExpiredSessions: false,
            rememberDrained: true
        )
    }

    private func sessionClosePayload(
        sessionID: UUID,
        ended: Bool,
        alreadyEnded: Bool,
        handoffFrameID: UInt64?,
        remainingActive: Int,
        harvest: SessionHarvest.Report = .skipped,
        reclaimed: Bool = false
    ) -> AgentBrokerValue {
        let display =
            "Session \(sessionID.uuidString) \(alreadyEnded ? "already ended" : "closed"). This session active=false. Other live sessions other_sessions_active=\(remainingActive > 0) remaining_active=\(remainingActive > 0) count=\(remainingActive). leftover_reasons are harvest skips — ignore them. Same conversation_id reopens this session."
        var payload: [String: AgentBrokerValue] = [
            "status": .string("ok"),
            "session_id": .string(sessionID.uuidString),
            "ended": .bool(ended),
            "active": .bool(false),
            "already_ended": .bool(alreadyEnded),
            "remaining_active": .from(remainingActive > 0),
            "other_sessions_active": .from(remainingActive > 0),
            "active_session_count": .from(remainingActive),
            "leftover_next_action": .string(
                harvest.leftoverReasons.isEmpty
                    ? "nothing to do"
                    : "ignore leftover_reasons; they are harvest skips, not errors. remaining_active is other sessions, not this one."
            ),
            "harvested": .bool(harvest.harvested),
            "promoted_count": .from(harvest.promotedCount),
            "promoted": .array(harvest.promoted.map { item in
                .object([
                    "memory_id": .string(item.memoryID),
                    "type": .string(item.type),
                    "preview": .string(item.preview),
                ])
            }),
            "leftover_count": .from(harvest.leftoverCount),
            "leftover_reasons": .array(harvest.leftoverReasons.map { .string($0) }),
            "reclaim_after_ms": .from(harvest.reclaimAfterMs),
            "reclaimed": .bool(reclaimed),
            "display_text": .string(display),
        ]
        if let handoffFrameID {
            payload["frame_id"] = .from(handoffFrameID)
            payload["committed"] = .bool(true)
        }
        payload.merge(harvestErrorPayload(harvest)) { _, new in new }
        return .object(payload)
    }

    /// True when an injected/explicit session_id belongs to a different named
    /// project than this `session_open`. That is a new job, not a resume.
    private func hintedSessionProjectConflicts(_ sessionID: UUID, project: String?) throws -> Bool {
        guard let requested = BrokerCommand.normalizedOrNil(project) else { return false }
        let existing: String?
        if let live = activeSessions[sessionID]?.manifest.project {
            existing = BrokerCommand.normalizedOrNil(live)
        } else {
            do {
                existing = BrokerCommand.normalizedOrNil(
                    try BrokerSessionPersistence.loadManifest(
                        rootURL: sessionRootURL,
                        sessionID: sessionID
                    ).project
                )
            } catch BrokerSessionPersistenceError.manifestNotFound {
                existing = nil
            }
        }
        guard let existing else { return false }
        return existing != requested
    }

    /// `handoff_latest` + `session_start` + optional `recall` in one round-trip (Phase 2).
    ///
    /// The handoff is intentionally projected to a bounded bootstrap shape.
    /// Callers that need frame metadata or the complete pending-task list can
    /// use `handoff_latest` explicitly.
    func sessionOpen(_ command: BrokerCommand.SessionOpen) async throws -> AgentBrokerValue {
        let project = command.project
        let repo = command.repo
        let agentID = command.agentID
        let runID = command.runID
        let cwd = command.cwd
        let conversationID = BrokerCommand.normalizedOrNil(command.conversationID)
        let requestedAgentID = BrokerCommand.normalizedOrNil(agentID)
        let requestedRunID = BrokerCommand.normalizedOrNil(runID)

        var inferredScope = cwd.map {
            MemorySemantics.inferScopeContext(currentDirectoryPath: $0)
        } ?? MemoryScopeContext()
        if project != nil || repo != nil {
            inferredScope = MemoryScopeContext(
                cwdPath: inferredScope.cwdPath,
                repoRootPath: inferredScope.repoRootPath,
                repoName: repo ?? project ?? inferredScope.repoName,
                projectName: project ?? inferredScope.projectName
            )
        }

        let priorUnique: (sessionID: UUID, runID: String)?
        if let requestedAgentID,
           let unique = try virtualSessions.findUniqueActiveLeased(
            agentID: requestedAgentID,
            project: inferredScope.projectName
           )
        {
            priorUnique = (unique.sessionID, unique.runID)
        } else {
            priorUnique = nil
        }
        let exactPair: BrokerSessionManifest?
        if let requestedAgentID, let requestedRunID {
            exactPair = try virtualSessions.findActive(agentID: requestedAgentID, runID: requestedRunID)
        } else {
            exactPair = nil
        }

        let hintedSessionResumable: Bool
        if exactPair == nil,
           priorUnique == nil,
           let hintedSessionID = command.sessionID
        {
            let exists = try activeSessions[hintedSessionID] != nil
                || virtualSessions.persistedStatus(for: hintedSessionID) == .active
            if exists {
                hintedSessionResumable = try !hintedSessionProjectConflicts(
                    hintedSessionID,
                    project: project
                )
            } else {
                hintedSessionResumable = false
            }
        } else {
            hintedSessionResumable = false
        }

        var conversationMatch: SessionOpenDecision.Match?
        if let conversationID {
            if let match = try BrokerSessionPersistence.findConversation(
                conversationID: conversationID,
                agentID: requestedAgentID,
                project: inferredScope.projectName,
                repo: inferredScope.repoName,
                rootURL: sessionRootURL
            ) {
                conversationMatch = .init(sessionID: match.sessionID, runID: match.runID)
            }
        }

        let openFacts = SessionOpenDecision.Facts(
            conversationID: conversationID,
            conversationMatch: conversationMatch,
            hintedSessionID: command.sessionID,
            hintedResumable: hintedSessionResumable,
            priorUnique: priorUnique.map { .init(sessionID: $0.sessionID, runID: $0.runID) },
            requestedRunID: requestedRunID
        )
        return try await SessionBootstrap.open(
            command: command,
            facts: openFacts,
            inferredScope: inferredScope,
            in: sessionBootstrapEnvironment()
        )
    }

    private func sessionBootstrapEnvironment() -> SessionBootstrap.Environment {
        SessionBootstrap.Environment(
            sessions: virtualSessions,
            longTermMemory: longTermMemory,
            nowMs: { BrokerClock.nowMs() },
            recall: { command in try await self.recall(command) },
            awaitQueryEmbedder: { sessionID in
                if await self.longTermMemory.isQueryEmbedderReady() {
                    await self.awaitQueryEmbedderIfNeeded(
                        memory: try await self.memory(for: sessionID)
                    )
                }
            },
            makeTokenizer: {
                let counter = try await TokenCounter.shared()
                return SessionOpenAssembly.Tokenizer(count: { text in await counter.count(text) })
            }
        )
    }

    private func sessionEndPayload(
        _ result: VirtualSessionStore.EndResult,
        reclaimed: Bool = false
    ) -> AgentBrokerValue {
        let remaining = result.activeCount
        // Use the harvest produced under endMutex+remember drain, not a reconstructed
        // disk snapshot that drops leftover reasons and promoted previews.
        let harvest = result.harvest
        let display: String
        switch result {
        case .idle:
            display = "No live session to end. This session active=false. Other live sessions other_sessions_active=false remaining_active=false count=0."
        case .ended(let endedID, _, _):
            display = "Session \(endedID.uuidString) ended. This session active=false. Other live sessions other_sessions_active=\(remaining > 0) remaining_active=\(remaining > 0) count=\(remaining)."
        }
        return .object([
            "status": .string("ok"),
            "session_id": result.sessionID.map { .string($0.uuidString) } ?? .null,
            "ended": .bool(result.ended),
            "active": .bool(false),
            "remaining_active": .from(result.remainingActive),
            "other_sessions_active": .from(result.remainingActive),
            "active_session_count": .from(result.activeCount),
            "harvested": .bool(harvest.harvested),
            "promoted_count": .from(harvest.promotedCount),
            "promoted": .array(harvest.promoted.map { item in
                .object([
                    "memory_id": .string(item.memoryID),
                    "type": .string(item.type),
                    "preview": .string(item.preview),
                ])
            }),
            "leftover_count": .from(harvest.leftoverCount),
            "leftover_reasons": .array(harvest.leftoverReasons.map { .string($0) }),
            "leftover_next_action": .string(
                harvest.leftoverReasons.isEmpty
                    ? "nothing to do"
                    : "ignore leftover_reasons; they are harvest skips, not errors. remaining_active is other sessions, not this one."
            ),
            "reclaim_after_ms": .from(harvest.reclaimAfterMs),
            "reclaimed": .bool(reclaimed),
            "display_text": .string(display),
        ].merging(harvestErrorPayload(harvest)) { _, new in new })
    }

    private func harvestErrorPayload(_ harvest: SessionHarvest.Report) -> [String: AgentBrokerValue] {
        guard let error = harvest.error, !error.isEmpty else { return [:] }
        return ["harvest_error": .string(error)]
    }

    private func makeHarvestCallback() -> @Sendable (VirtualSessionStore.SessionState) async -> SessionHarvest.Report {
        let longTerm = longTermMemory
        let settings = promotionSettings
        let retention = retentionSettings
        let scope = scopeContext
        return { state in
            let events = (try? BrokerSessionPersistence.loadEvents(from: state.eventLogURL)) ?? []
            return await SessionHarvest.run(
                sessionMemory: state.memory,
                longTermMemory: longTerm,
                sessionID: state.id,
                manifest: state.manifest,
                events: events,
                scope: scope,
                settings: settings,
                retention: retention,
                nowMs: BrokerClock.nowMs()
            )
        }
    }

    private func loadHarvestReport(sessionID: UUID) -> SessionHarvest.Report {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ) else {
            return .skipped
        }
        let immediate = manifest.reclaimAfterMs == manifest.harvestedAtMs
        return SessionHarvest.Report(
            harvested: manifest.harvestedAtMs != nil,
            promotedCount: manifest.promotedCount,
            leftoverDocumentCount: immediate ? 0 : 1,
            leftoverLockedCount: 0,
            reclaimAfterMs: manifest.reclaimAfterMs,
            error: manifest.harvestError,
            alreadyHarvested: manifest.harvestedAtMs != nil
        )
    }

    /// - Parameter rememberDrained: the caller already holds `rememberMutex`
    ///   (session teardown under `.rememberDrain`); otherwise it is taken here.
    private func harvestPersistedSession(sessionID: UUID, rememberDrained: Bool) async -> SessionHarvest.Report {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ) else {
            return .skipped
        }
        if manifest.harvestedAtMs != nil, manifest.harvestError == nil {
            return loadHarvestReport(sessionID: sessionID)
        }
        let events = (try? BrokerSessionPersistence.loadEvents(
            from: URL(fileURLWithPath: manifest.eventLogPath)
        )) ?? []
        let storeURL = URL(fileURLWithPath: manifest.storePath)
        let report: SessionHarvest.Report
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let longTerm = longTermMemory
                let scope = scopeContext
                let settings = promotionSettings
                let retention = retentionSettings
                let now = BrokerClock.nowMs()
                report = try await endedSessions.withMemory(at: storeURL) { memory in
                    await SessionHarvest.run(
                        sessionMemory: memory,
                        longTermMemory: longTerm,
                        sessionID: sessionID,
                        manifest: manifest,
                        events: events,
                        scope: scope,
                        settings: settings,
                        retention: retention,
                        nowMs: now
                    )
                }
            } catch {
                report = SessionHarvest.Report(
                    harvested: false,
                    promotedCount: 0,
                    leftoverDocumentCount: 0,
                    leftoverLockedCount: 0,
                    reclaimAfterMs: nil,
                    error: error.localizedDescription,
                    alreadyHarvested: false
                )
            }
        } else {
            report = SessionHarvest.Report(
                harvested: true,
                promotedCount: 0,
                leftoverDocumentCount: 0,
                leftoverLockedCount: 0,
                reclaimAfterMs: BrokerClock.nowMs(),
                error: nil,
                alreadyHarvested: false
            )
        }
        if let hook = persistedHarvestHookForTesting {
            await hook(sessionID)
        }
        if rememberDrained {
            persistHarvestUnlessRebound(sessionID: sessionID, report: report)
        } else {
            // Lock order commandMutex -> rememberMutex, the same as `.rememberDrain`.
            await rememberMutex.withLock { [self] in
                await persistHarvestUnlessRebound(sessionID: sessionID, report: report)
            }
        }
        return report
    }

    /// Marks the harvested session `.ended` unless it is live again. A remember
    /// (rememberMutex only) can rebind an expired-lease session while the harvest
    /// awaits; that session is back in use, so its manifest is left alone and its
    /// own end will harvest it. Run with rememberMutex held so no rebind is in flight.
    private func persistHarvestUnlessRebound(sessionID: UUID, report: SessionHarvest.Report) {
        guard activeSessions[sessionID] == nil else { return }
        _ = try? virtualSessions.persistHarvestToDisk(
            sessionID: sessionID,
            report: report,
            markEnded: true
        )
    }

    package func setPersistedHarvestHookForTesting(_ hook: (@Sendable (UUID) async -> Void)?) {
        persistedHarvestHookForTesting = hook
    }

    @discardableResult
    private func reclaimSessionIfDue(sessionID: UUID, force: Bool = false) async -> Bool {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ) else {
            return false
        }
        let now = BrokerClock.nowMs()
        guard SessionReclaim.isReclaimable(manifest: manifest, nowMs: now, force: force) else {
            return false
        }
        do {
            _ = try SessionReclaim.unlink(
                manifest: manifest,
                sessionRootURL: sessionRootURL,
                nowMs: now
            )
            return true
        } catch {
            return false
        }
    }

    private struct SessionStoreMaintainCounts: Sendable {
        var zombiesToEnd: Int
        var harvests: Int
        var unlinks: Int
    }

    @discardableResult
    private func maintainSessionStores(
        apply: Bool,
        forceReclaim: Bool,
        endExpiredSessions: Bool,
        rememberDrained: Bool
    ) async -> SessionStoreMaintainCounts {
        let now = BrokerClock.nowMs()
        let recentlyClosedMs = retentionSettings.recentlyClosedMs
        let manifests = (try? BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)) ?? []
        let liveIDs = Set(activeSessions.keys)
        var zombiesToEnd = 0
        var harvests = 0
        var unlinks = 0

        var zombieIDs = Set<UUID>()
        for manifest in manifests where SessionReclaim.isZombie(
            manifest: manifest,
            liveIDs: liveIDs,
            nowMs: now
        ) {
            let abandoned = SessionReclaim.isAbandonedZombie(
                manifest: manifest,
                liveIDs: liveIDs,
                nowMs: now,
                recentlyClosedMs: recentlyClosedMs
            )
            guard endExpiredSessions || abandoned else { continue }
            zombiesToEnd += 1
            zombieIDs.insert(manifest.sessionID)
            harvests += 1
            if apply {
                _ = await harvestPersistedSession(sessionID: manifest.sessionID, rememberDrained: rememberDrained)
            }
        }

        let afterZombies = (try? BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)) ?? []
        for manifest in afterZombies {
            if !zombieIDs.contains(manifest.sessionID),
               manifest.status == .ended,
               manifest.harvestedAtMs == nil || manifest.harvestError != nil {
                harvests += 1
                if apply {
                    _ = await harvestPersistedSession(sessionID: manifest.sessionID, rememberDrained: rememberDrained)
                }
            }
            let current = (try? BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: manifest.sessionID
            )) ?? manifest
            if SessionReclaim.isReclaimable(manifest: current, nowMs: now, force: forceReclaim) {
                unlinks += 1
                if apply {
                    _ = await reclaimSessionIfDue(sessionID: current.sessionID, force: forceReclaim)
                }
            }
        }

        return SessionStoreMaintainCounts(
            zombiesToEnd: zombiesToEnd,
            harvests: harvests,
            unlinks: unlinks
        )
    }

    func memoryMaintain(
        _ command: BrokerCommand.MemoryMaintain,
        endExpiredSessions: Bool = true
    ) async throws -> AgentBrokerValue {
        let apply = command.apply
        let force = command.forceReclaim
        let now = BrokerClock.nowMs()
        // memory_maintain holds commandMutex only (startup holds nothing).
        let sessionCounts = await maintainSessionStores(
            apply: apply,
            forceReclaim: force,
            endExpiredSessions: endExpiredSessions,
            rememberDrained: false
        )
        let zombiesToEnd = sessionCounts.zombiesToEnd
        let harvests = sessionCounts.harvests
        let unlinks = sessionCounts.unlinks
        var quarantineSoftDeletes = 0

        let documents = try await longTermMemory.corpusSourceDocuments()
        let accessStats = await longTermMemory.accessStatsSnapshot()
        let quarantineIDs = documents.compactMap { document -> UInt64? in
            MemoryRetention.isQuarantineCandidate(
                metadata: document.metadata,
                stats: accessStats[document.frameId],
                nowMs: now,
                settings: retentionSettings
            ) ? document.frameId : nil
        }
        quarantineSoftDeletes = quarantineIDs.count
        if apply {
            do {
                try await longTermMemory.delete(frameIds: quarantineIDs)
            } catch let partial as MemoryOrchestrator.PartialDeleteError {
                // Flush the committed part; the error states how many were deleted.
                do {
                    try await longTermMemory.flush()
                } catch {
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "maintain quarantine flush after partial delete",
                        fallback: "report the partial delete; the WAL applies it on reopen"
                    )
                }
                throw partial
            }
            if !quarantineIDs.isEmpty {
                try await longTermMemory.flush()
            }
        }

        let display = apply
            ? "Maintain apply: zombies=\(zombiesToEnd) harvests=\(harvests) unlinks=\(unlinks) quarantine=\(quarantineSoftDeletes)"
            : "Maintain dry-run: zombies=\(zombiesToEnd) harvests=\(harvests) unlinks=\(unlinks) quarantine=\(quarantineSoftDeletes)"
        return .object([
            "status": .string("ok"),
            "dry_run": .bool(!apply),
            "zombies_to_end": .from(zombiesToEnd),
            "harvests": .from(harvests),
            "unlinks": .from(unlinks),
            "quarantine_soft_deletes": .from(quarantineSoftDeletes),
            "display_text": .string(display),
        ])
    }

    private func renderSessionLifecycleResult(
        _ result: VirtualSessionStore.LifecycleResult
    ) -> AgentBrokerValue {
        let state = result.state
        return .object([
            "status": .string("ok"),
            "session_id": .string(state.id.uuidString),
            "agent_id": .string(state.manifest.agentID),
            "run_id": .string(state.manifest.runID),
            "project": .from(state.manifest.project),
            "repo": .from(state.manifest.repo),
            "resumed": .bool(result.resumed),
            "recovered_lease": .bool(result.recoveredLease),
            "store_path": .string(state.storeURL.path),
            "event_log_path": .string(state.eventLogURL.path),
        ])
    }
}
