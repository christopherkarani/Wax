import Foundation
import WaxCore

extension AgentBrokerService {
    func sessionStart(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let explicitSessionID = try parseOptionalSessionID(args)
        let sessionID = explicitSessionID ?? UUID()
        if let active = activeSessions[sessionID] {
            return renderSessionLifecycleResult(state: active, resumed: false, recoveredLease: false)
        }

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            throw BrokerValidationError.invalid("session_id already exists; use session_resume to reopen it")
        }

        let sessionURL = sessionRootURL.appendingPathComponent("\(sessionID.uuidString).wax")
        let eventLogURL = BrokerSessionPersistence.eventLogURL(rootURL: sessionRootURL, sessionID: sessionID)
        let memory = try await openSessionMemory(at: sessionURL)

        let nowMs = Self.nowMs()
        let agentID = try args.optionalString("agent_id") ?? scopeContext.repoName ?? "wax-agent"
        let runID = try args.optionalString("run_id") ?? UUID().uuidString
        let manifest = BrokerSessionManifest(
            sessionID: sessionID,
            agentID: agentID,
            runID: runID,
            project: scopeContext.projectName,
            repo: scopeContext.repoName,
            storePath: sessionURL.path,
            eventLogPath: eventLogURL.path,
            status: .active,
            brokerLeaseOwnerID: brokerInstanceID,
            leaseExpiresAtMs: nowMs + Int64(Self.defaultSessionLeaseSeconds * 1000),
            createdAtMs: nowMs,
            updatedAtMs: nowMs
        )
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: sessionID,
                agentID: agentID,
                runID: runID,
                timestampMs: nowMs,
                kind: .started,
                payload: [
                    "project": manifest.project ?? "",
                    "repo": manifest.repo ?? "",
                ]
            ),
            to: eventLogURL
        )
        try BrokerSessionPersistence.saveManifest(manifest, to: manifestURL)
        let state = SessionState(
            id: sessionID,
            manifest: manifest,
            manifestURL: manifestURL,
            eventLogURL: eventLogURL,
            storeURL: sessionURL,
            memory: memory
        )
        activeSessions[sessionID] = state
        return renderSessionLifecycleResult(state: state, resumed: false, recoveredLease: false)
    }

    func sessionResume(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let explicitSessionID = try parseOptionalSessionID(args)
        let requestedAgentID = try args.optionalString("agent_id")
        let requestedRunID = try args.optionalString("run_id")

        let manifest = try resolveSessionManifest(
            explicitSessionID: explicitSessionID,
            agentID: requestedAgentID,
            runID: requestedRunID
        )
        guard manifest.status == .active else {
            throw BrokerValidationError.invalid("session_id has already been ended and cannot be resumed")
        }

        if let existing = activeSessions[manifest.sessionID] {
            return renderSessionLifecycleResult(state: existing, resumed: true, recoveredLease: false)
        }

        let nowMs = Self.nowMs()
        let recoveredLease = manifest.brokerLeaseOwnerID != nil && manifest.brokerLeaseOwnerID != brokerInstanceID
        let memory = try await openSessionMemory(at: URL(fileURLWithPath: manifest.storePath))
        var refreshed = manifest
        refreshed.brokerLeaseOwnerID = brokerInstanceID
        refreshed.leaseExpiresAtMs = nowMs + Int64(Self.defaultSessionLeaseSeconds * 1000)
        refreshed.updatedAtMs = nowMs

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: manifest.sessionID)
        let eventLogURL = URL(fileURLWithPath: refreshed.eventLogPath)
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: refreshed.sessionID,
                agentID: refreshed.agentID,
                runID: refreshed.runID,
                timestampMs: nowMs,
                kind: .resumed,
                payload: [
                    "recovered_lease": recoveredLease ? "true" : "false",
                ]
            ),
            to: eventLogURL
        )
        try BrokerSessionPersistence.saveManifest(refreshed, to: manifestURL)
        let state = SessionState(
            id: refreshed.sessionID,
            manifest: refreshed,
            manifestURL: manifestURL,
            eventLogURL: eventLogURL,
            storeURL: URL(fileURLWithPath: refreshed.storePath),
            memory: memory
        )
        activeSessions[refreshed.sessionID] = state
        return renderSessionLifecycleResult(state: state, resumed: true, recoveredLease: recoveredLease)
    }

    func sessionEnd(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let sessionID = try parseOptionalSessionID(args)
        let target: UUID
        switch (sessionID, activeSessions.count) {
        case let (.some(explicit), _):
            guard activeSessions[explicit] != nil else {
                throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
            }
            target = explicit
        case (.none, 1):
            target = activeSessions.keys.first!
        case (.none, 0):
            return .object([
                "status": .string("ok"),
                "session_id": .null,
                "active": .bool(false),
            ])
        default:
            throw BrokerValidationError.invalid("session_id is required when more than one session is active")
        }
        if let state = activeSessions[target] {
            var manifest = state.manifest
            manifest.status = .ended
            manifest.updatedAtMs = Self.nowMs()
            manifest.brokerLeaseOwnerID = nil
            manifest.leaseExpiresAtMs = nil
            try BrokerSessionPersistence.saveManifest(manifest, to: state.manifestURL)
            try BrokerSessionPersistence.appendEvent(
                BrokerSessionEvent(
                    sessionID: state.id,
                    agentID: manifest.agentID,
                    runID: manifest.runID,
                    timestampMs: manifest.updatedAtMs,
                    kind: .ended
                ),
                to: state.eventLogURL
            )
            try await state.memory.flush()
            try await state.memory.close()
            activeSessions.removeValue(forKey: target)
        }
        return .object([
            "status": .string("ok"),
            "session_id": .string(target.uuidString),
            "active": .from(!activeSessions.isEmpty),
        ])
    }

    func handoff(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let content = try args.requiredStringPreservingWhitespace("content", maxBytes: Self.maxContentBytes)
        let project = try args.optionalString("project")
        let pendingTasks = try args.optionalStringArray("pending_tasks") ?? []
        let sessionID = try parseOptionalSessionID(args)
        try validateActiveSession(sessionID)
        let frameId = try await longTermMemory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: false
        )
        if let sessionID {
            try await recordHandoff(sessionID: sessionID, content: content)
        }
        try await longTermMemory.flush()
        return .object([
            "status": .string("ok"),
            "frame_id": .from(frameId),
            "committed": .bool(true),
            "display_text": .string("Handoff stored (frame \(frameId))."),
        ])
    }

    func handoffLatest(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let project = try args.optionalString("project")
        guard let latest = try await longTermMemory.latestHandoff(project: project) else {
            return .object(["found": .bool(false)])
        }
        return .object([
            "found": .bool(true),
            "frame_id": .from(latest.frameId),
            "timestamp_ms": .from(latest.timestampMs),
            "project": .from(latest.project),
            "pending_tasks": .array(latest.pendingTasks.map { .string($0) }),
            "content": .string(latest.content),
            "display_text": .string(latest.content),
        ])
    }

    func compactContext(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let tokenBudget = try args.optionalInt("token_budget") ?? 1800
        guard (128...Self.maxCompactContextTokenBudget).contains(tokenBudget) else {
            throw BrokerValidationError.invalid("token_budget must be between 128 and \(Self.maxCompactContextTokenBudget)")
        }
        let maxItems = try args.optionalInt("max_items") ?? 12
        guard (1...64).contains(maxItems) else {
            throw BrokerValidationError.invalid("max_items must be between 1 and 64")
        }
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let sessionID = try resolveSessionID(
            try parseOptionalSessionID(args),
            requiringUnambiguousWorkingMemory: true
        )
        if let sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await sessionMemory.flush()
            try await refreshSessionManifest(sessionID)
        }
        try await longTermMemory.flush()
        let assembled = try await assembleCompactContext(
            query: query,
            sessionID: sessionID,
            mode: mode,
            tokenBudget: tokenBudget,
            maxItems: maxItems
        )
        if let sessionID {
            try await recordCheckpoint(
                sessionID: sessionID,
                summary: assembled.summary,
                compactedText: assembled.compactedText
            )
        }
        return .object([
            "query": .string(query),
            "token_budget": .from(tokenBudget),
            "used_tokens": .from(assembled.usedTokens),
            "summary": .string(assembled.summary),
            "short_context": .array(assembled.short.map(renderLayeredMemoryHit)),
            "medium_context": .array(assembled.medium.map(renderLayeredMemoryHit)),
            "long_context": .array(assembled.long.map(renderLayeredMemoryHit)),
            "compacted_text": .string(assembled.compactedText),
            "display_text": .string(assembled.compactedText),
        ])
    }

    func resolveSessionManifest(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?
    ) throws -> BrokerSessionManifest {
        if let explicitSessionID {
            return try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: explicitSessionID)
        }

        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
        let filtered = manifests.filter { manifest in
            guard manifest.status == .active else { return false }
            if let agentID, manifest.agentID != agentID { return false }
            if let runID, manifest.runID != runID { return false }
            return true
        }
        guard let match = filtered.first else {
            throw BrokerValidationError.invalid("No resumable session manifest matched the requested selectors")
        }
        return match
    }

    private func renderSessionLifecycleResult(
        state: SessionState,
        resumed: Bool,
        recoveredLease: Bool
    ) -> AgentBrokerValue {
        .object([
            "status": .string("ok"),
            "session_id": .string(state.id.uuidString),
            "agent_id": .string(state.manifest.agentID),
            "run_id": .string(state.manifest.runID),
            "project": .from(state.manifest.project),
            "repo": .from(state.manifest.repo),
            "resumed": .bool(resumed),
            "recovered_lease": .bool(recoveredLease),
            "store_path": .string(state.storeURL.path),
            "event_log_path": .string(state.eventLogURL.path),
        ])
    }

    func refreshSessionManifest(_ sessionID: UUID) async throws {
        guard var state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        state.manifest.updatedAtMs = Self.nowMs()
        state.manifest.brokerLeaseOwnerID = brokerInstanceID
        state.manifest.leaseExpiresAtMs = state.manifest.updatedAtMs + Int64(Self.defaultSessionLeaseSeconds * 1000)
        try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
        activeSessions[sessionID] = state
    }

    func appendSessionEvent(
        sessionID: UUID,
        kind: BrokerSessionEvent.Kind,
        payload: [String: String] = [:]
    ) async throws {
        guard let state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: sessionID,
                agentID: state.manifest.agentID,
                runID: state.manifest.runID,
                timestampMs: Self.nowMs(),
                kind: kind,
                payload: payload
            ),
            to: state.eventLogURL
        )
    }

    func recordRetrievalHits(
        sessionID: UUID,
        query: String,
        hits: [(frameID: UInt64, score: Float)],
        memory: MemoryOrchestrator
    ) async throws {
        guard !hits.isEmpty else { return }
        let queryHash = Self.stableHash(query.lowercased())
        var seenFrameIDs = Set<UInt64>()
        for hit in hits {
            let frameID = hit.frameID
            guard let canonicalFrameID = await bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory) else {
                continue
            }
            guard seenFrameIDs.insert(canonicalFrameID).inserted else { continue }
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .retrievalHit,
                payload: [
                    "frame_id": String(canonicalFrameID),
                    "score": String(hit.score),
                    "query_hash": queryHash,
                ]
            )
        }
    }

    func recordHandoff(sessionID: UUID, content: String) async throws {
        guard var state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        let nowMs = Self.nowMs()
        state.manifest.lastHandoffAtMs = nowMs
        state.manifest.latestHandoff = MemorySemantics.summarizeCandidate(content, maxLength: 220)
        state.manifest.updatedAtMs = nowMs
        try await appendSessionEvent(
            sessionID: sessionID,
            kind: .handoff,
            payload: [
                "summary": state.manifest.latestHandoff ?? "",
            ]
        )
        try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
        activeSessions[sessionID] = state
    }

    func recordCheckpoint(sessionID: UUID, summary: String, compactedText: String) async throws {
        guard var state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        let nowMs = Self.nowMs()
        state.manifest.lastCheckpointAtMs = nowMs
        state.manifest.lastCompactionAtMs = nowMs
        state.manifest.checkpointCount += 1
        state.manifest.latestSummary = summary
        state.manifest.updatedAtMs = nowMs
        try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
        activeSessions[sessionID] = state
        try await appendSessionEvent(
            sessionID: sessionID,
            kind: .checkpoint,
            payload: [
                "summary": summary,
                "content_hash": Self.stableHash(compactedText),
            ]
        )
    }

    func sessionSignals(for sessionID: UUID) async throws -> [UInt64: BrokerSessionRecallSignals] {
        if let state = activeSessions[sessionID] {
            return BrokerSessionPersistence.recallSignals(
                from: try BrokerSessionPersistence.loadEvents(from: state.eventLogURL)
            )
        }
        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        return BrokerSessionPersistence.recallSignals(
            from: try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        )
    }
}
