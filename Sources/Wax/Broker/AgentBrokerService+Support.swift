import Foundation
import WaxCore

extension AgentBrokerService {
    func refreshSessionManifest(_ sessionID: UUID) async throws {
        try virtualSessions.refreshManifest(sessionID)
    }

    func appendSessionEvent(
        sessionID: UUID,
        kind: BrokerSessionEvent.Kind,
        payload: [String: String] = [:]
    ) async throws {
        try virtualSessions.appendEvent(sessionID: sessionID, kind: kind, payload: payload)
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
        let summary = MemorySemantics.summarizeCandidate(content, maxLength: 220)
        try await appendSessionEvent(
            sessionID: sessionID,
            kind: .handoff,
            payload: [
                "summary": summary,
            ]
        )
        try virtualSessions.updateLive(sessionID) { state in
            let nowMs = BrokerClock.nowMs()
            state.manifest.lastHandoffAtMs = nowMs
            state.manifest.latestHandoff = summary
            state.manifest.updatedAtMs = nowMs
        }
    }

    func recordCheckpoint(sessionID: UUID, summary: String, compactedText: String) async throws {
        try virtualSessions.updateLive(sessionID) { state in
            let nowMs = BrokerClock.nowMs()
            state.manifest.lastCheckpointAtMs = nowMs
            state.manifest.lastCompactionAtMs = nowMs
            state.manifest.checkpointCount += 1
            state.manifest.latestSummary = summary
            state.manifest.updatedAtMs = nowMs
        }
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

    func layeredRecallStores() -> LayeredRecall.Stores {
        // Snapshot discipline lives behind the BrokerRecall seam; Compact
        // assembly builds through the same function.
        BrokerRecall.makeStores(
            snapshot: activeSessions,
            longTermMemory: longTermMemory,
            endedSessions: endedSessions,
            preview: { Wax.dehighlightedPreviewText($0 ?? "") },
            canonicalFrameID: { frameID, memory in
                await self.bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory)
            },
            nowMs: { BrokerClock.nowMs() }
        )
    }

    func layeredMemoryGet(reference: MemoryReference) async throws -> LayeredMemoryHit {
        switch reference {
        case .durable(let frameID):
            let document = try await requireDocument(frameID: frameID, memory: longTermMemory)
            await longTermMemory.recordAccess(frameId: document.frameId)
            return LayeredMemoryHit(
                id: .durable(frameID: frameID),
                score: 0,
                text: document.text,
                preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                metadata: document.metadata,
                explanations: ["durable memory"],
                timestampMs: document.timestampMs
            )
        case .working(let sessionID, let frameID), .episodic(let sessionID, let frameID):
            if let state = activeSessions[sessionID] {
                let document = try await requireDocument(frameID: frameID, memory: state.memory)
                await state.memory.recordAccess(frameId: document.frameId)
                return LayeredMemoryHit(
                    id: MemoryID.make(horizon: reference.horizon, sessionID: sessionID, frameID: frameID),
                    agentID: state.manifest.agentID,
                    runID: state.manifest.runID,
                    score: 0,
                    text: document.text,
                    preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                    metadata: document.metadata,
                    explanations: [reference.horizon == .working ? "current session" : "recent session episode"],
                    timestampMs: document.timestampMs
                )
            }
            let document = try await endedSessions.document(
                EndedSessionDocumentQuery(sessionID: sessionID, frameID: frameID)
            )
            return LayeredMemoryHit(
                id: MemoryID.make(horizon: reference.horizon, sessionID: sessionID, frameID: frameID),
                agentID: document.agentID,
                runID: document.runID,
                score: 0,
                text: document.text,
                preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                metadata: document.metadata,
                explanations: [reference.horizon == .working ? "current session" : "recent session episode"],
                timestampMs: document.timestampMs
            )
        }
    }

    func memory(for sessionID: UUID?) async throws -> MemoryOrchestrator {
        switch try await virtualSessions.ensureLive(sessionID) {
        case .none:
            return longTermMemory
        case .live(let memory):
            return memory
        }
    }

    func validateActiveSession(_ sessionID: UUID?) async throws {
        try await virtualSessions.validateActiveOrRebind(sessionID)
    }

    /// Brief inspection open: it never commits a text-index catch-up.
    func openSessionMemory(at url: URL) async throws -> MemoryOrchestrator {
        try await virtualSessions.openExistingSessionMemory(at: url, catchUp: false)
    }

    func writeScope(for sessionID: UUID?, clientCWD: String? = nil) -> MemoryScopeContext {
        if let sessionID, let session = activeSessions[sessionID] {
            let project = session.manifest.project
            let repo = session.manifest.repo
            if project != nil || repo != nil {
                return MemoryScopeContext(
                    cwdPath: clientCWD,
                    repoRootPath: nil,
                    repoName: repo,
                    projectName: project
                )
            }
        }
        if let clientCWD {
            return MemorySemantics.inferScopeContext(currentDirectoryPath: clientCWD)
        }
        return MemoryScopeContext()
    }

    func agentFacingPreview(_ text: String?) -> String {
        Wax.dehighlightedPreviewText(text ?? "")
    }

    func matchesExportProject(_ value: String?, project: String?) -> Bool {
        guard let project else { return true }
        if let value, !value.isEmpty, value != project {
            return false
        }
        return true
    }

    func resolveSessionID(_ explicit: UUID?) throws -> UUID? {
        if let explicit { return explicit }
        if activeSessions.count == 1 {
            return activeSessions.keys.first
        }
        return nil
    }

    enum SessionResolutionPolicy: Sendable, Equatable {
        /// Do not infer a working session from live sessions.
        case unscoped
        /// Infer the sole live session; throw if more than one is live.
        case requireUnambiguousWorking
        /// Infer the sole live session; if more than one is live, search durable only.
        case durableOnlyWhenAmbiguous
    }

    enum ResolvedSessionScope: Sendable, Equatable {
        case session(UUID)
        case durableOnly
        case none
    }

    /// Lane visibility after session-scope resolution: a resolved session keeps
    /// the request, an unscoped search drops working, ambiguity keeps durable only.
    static func scopedHorizons(scope: ResolvedSessionScope, requested: HorizonSet) -> HorizonSet {
        switch scope {
        case .session:
            return requested
        case .durableOnly:
            return .durable
        case .none:
            return requested.subtracting(.working)
        }
    }

    func resolveSessionScope(
        _ explicit: UUID?,
        policy: SessionResolutionPolicy
    ) throws -> ResolvedSessionScope {
        if let explicit { return .session(explicit) }
        switch policy {
        case .unscoped:
            return .none
        case .requireUnambiguousWorking:
            switch activeSessions.count {
            case 0:
                return .none
            case 1:
                return .session(activeSessions.keys.first!)
            default:
                throw BrokerValidationError.invalid("session_id is required when more than one session is active")
            }
        case .durableOnlyWhenAmbiguous:
            switch activeSessions.count {
            case 0:
                return .none
            case 1:
                return .session(activeSessions.keys.first!)
            default:
                return .durableOnly
            }
        }
    }

    func promotionSettingsMerging(_ command: BrokerCommand.SessionSynthesize) -> BrokerPromotionSettings {
        BrokerPromotionSettings(
            minimumConfidence: command.minimumConfidence ?? promotionSettings.minimumConfidence,
            minimumRecallCount: command.minimumRecallCount ?? promotionSettings.minimumRecallCount,
            maxCandidates: command.maxCandidates ?? promotionSettings.maxCandidates
        )
    }

    func validateDurableWriteContent(content: String, metadata: [String: String]) throws {
        let semantics = MemorySemantics.parse(metadata: metadata, nowMs: BrokerClock.nowMs())
        guard semantics.durability == .durable || semantics.durability == .locked else { return }
        if let detected = SecretHeuristics.detectSecretLikeContent(content, metadata: metadata) {
            throw BrokerValidationError.invalid("Refusing to store durable memory containing secret-like content (\(detected))")
        }
    }

    func frameText(frameID: UInt64, memory: MemoryOrchestrator) async -> String? {
        if let data = try? await memory.wax.frameContent(frameId: frameID),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return try? await memory.corpusSourceDocuments().first(where: { $0.frameId == frameID })?.text
    }

    func requireDocument(
        frameID: UInt64,
        memory: MemoryOrchestrator
    ) async throws -> MemoryOrchestrator.CorpusSourceDocument {
        guard let document = try await memory.corpusSourceDocuments().first(where: { $0.frameId == frameID }) else {
            throw BrokerValidationError.invalid("No memory document found for frame_id \(frameID)")
        }
        return document
    }

    func canonicalDocumentFrameID(
        for frameID: UInt64,
        memory: MemoryOrchestrator
    ) async throws -> UInt64 {
        let meta = try await memory.wax.frameMetaIncludingPending(frameId: frameID)
        if meta.role == .chunk, let parentID = meta.parentId {
            return parentID
        }
        return frameID
    }

    func bestEffortCanonicalDocumentFrameID(
        for frameID: UInt64,
        memory: MemoryOrchestrator
    ) async -> UInt64? {
        do {
            return try await canonicalDocumentFrameID(for: frameID, memory: memory)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "broker canonical frame lookup",
                fallback: "skip stale search hit"
            )
            return nil
        }
    }


    static func makeMemoryReference(frameID: UInt64) -> String {
        LayeredRecall.makeMemoryReference(frameID: frameID)
    }

    static func makeMemoryReference(_ horizon: MemoryHorizon, sessionID: UUID, frameID: UInt64) -> String {
        LayeredRecall.makeMemoryReference(horizon, sessionID: sessionID, frameID: frameID)
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
