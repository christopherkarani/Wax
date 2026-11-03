import Foundation
import WaxCore

extension AgentBrokerService {
    func recall(_ command: BrokerCommand.Recall) async throws -> AgentBrokerValue {
        let mode = command.mode

        // Rebind session lane before resolving project from session manifest (C4).
        if let sessionID = command.sessionID {
            _ = try await memory(for: sessionID)
        }

        // Session stores attach on their own follow task. After MiniLM is ready,
        // wait for that attach here so a session-scoped first recall is hybrid.
        // Skip when long-term is still loading so a timeout does not become a
        // second 30s hold on commandMutex.
        if mode != .textOnly, let sessionID = command.sessionID,
           await longTermMemory.isQueryEmbedderReady() {
            await awaitQueryEmbedderIfNeeded(memory: try await memory(for: sessionID))
        }
        // Fetch + merge + pack live behind the BrokerRecall seam. The module
        // takes no lock: this runs under commandMutex with the embedder
        // already awaited above.
        let packed = try await BrokerRecall.recall(
            command,
            in: BrokerRecall.Environment(
                longTermMemory: longTermMemory,
                sessions: virtualSessions,
                endedSessions: endedSessions,
                preview: { Wax.dehighlightedPreviewText($0 ?? "") },
                canonicalFrameID: { frameID, memory in
                    await self.bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory)
                },
                nowMs: { BrokerClock.nowMs() }
            )
        )

        if let sessionID = command.sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: command.query,
                hits: packed.hits.compactMap { hit in
                    guard hit.horizon == .working else { return nil }
                    return (hit.frameID, hit.score)
                },
                memory: sessionMemory
            )
            await sessionMemory.recordImpressions(
                frameIds: packed.hits.filter { $0.horizon == .working }.map(\.frameID)
            )
        }
        await longTermMemory.recordImpressions(
            frameIds: packed.hits.filter { $0.horizon == .durable }.map(\.frameID)
        )
        return packed.payload
    }

    func search(_ command: BrokerCommand.Search) async throws -> AgentBrokerValue {
        let parsedFilters = command.filters
        let mode = command.mode
        let sessionMemory = try await memory(for: parsedFilters.sessionId)
        if mode != .textOnly, parsedFilters.sessionId != nil, await longTermMemory.isQueryEmbedderReady() {
            await awaitQueryEmbedderIfNeeded(memory: sessionMemory)
        }
        let packed = try await BrokerRecall.search(
            command,
            in: BrokerRecall.Environment(
                longTermMemory: longTermMemory,
                sessions: virtualSessions,
                endedSessions: endedSessions,
                preview: { Wax.dehighlightedPreviewText($0 ?? "") },
                canonicalFrameID: { frameID, memory in
                    await self.bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory)
                },
                nowMs: { BrokerClock.nowMs() }
            )
        )
        if let sessionID = parsedFilters.sessionId {
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: command.query,
                hits: packed.sessionHits.map { ($0.frameId, $0.score) },
                memory: sessionMemory
            )
        }
        return packed.payload
    }

    func memorySearch(_ command: BrokerCommand.MemorySearch) async throws -> AgentBrokerValue {
        let requested = command.horizons
        let sessionLanes = requested.intersection([.working, .episodic])
        let policy: SessionResolutionPolicy
        if sessionLanes.isEmpty {
            policy = .unscoped
        } else {
            policy = requested.contains(.durable) ? .durableOnlyWhenAmbiguous : .requireUnambiguousWorking
        }
        let scope = try resolveSessionScope(command.sessionID, policy: policy)
        let sessionID: UUID?
        if case .session(let resolved) = scope {
            sessionID = resolved
        } else {
            sessionID = nil
        }
        let horizons = Self.scopedHorizons(scope: scope, requested: requested)
        // Fetch + merge + fence + pack live behind the BrokerRecall seam. The
        // module takes no lock: this runs under commandMutex, like recall.
        let packed = try await BrokerRecall.memorySearch(
            command,
            sessionID: sessionID,
            horizons: horizons,
            in: BrokerRecall.Environment(
                longTermMemory: longTermMemory,
                sessions: virtualSessions,
                endedSessions: endedSessions,
                preview: { Wax.dehighlightedPreviewText($0 ?? "") },
                canonicalFrameID: { frameID, memory in
                    await self.bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory)
                },
                nowMs: { BrokerClock.nowMs() }
            )
        )

        if let sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: command.query,
                hits: packed.hits.compactMap { hit in
                    guard hit.horizon == .working else { return nil }
                    return (hit.frameID, hit.score)
                },
                memory: sessionMemory
            )
        }
        return packed.payload
    }

    func memoryGet(_ command: BrokerCommand.MemoryGet) async throws -> AgentBrokerValue {
        let hit = try await layeredMemoryGet(reference: command.memoryID)
        return .object([
            "memory_id": .string(hit.reference),
            "horizon": .string(hit.horizon.rawValue),
            "session_id": .from(hit.sessionID?.uuidString),
            "agent_id": .from(hit.agentID),
            "run_id": .from(hit.runID),
            "frame_id": .from(hit.frameID),
            "timestamp_ms": .from(hit.timestampMs),
            "text": .string(hit.text),
            "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
            "explanations": .array(hit.explanations.map(AgentBrokerValue.string)),
            "display_text": .string(hit.text),
        ])
    }

    package func prewarmEmbedder() async {
        guard !noEmbedder else { return }
        await awaitQueryEmbedderIfNeeded(memory: longTermMemory)
        _ = try? await longTermMemory.searchExecution(
            query: "wax",
            mode: .hybrid(alpha: 0.5),
            topK: 1,
            frameFilter: nil,
            timeRange: nil
        )
        guard await longTermMemory.isQueryEmbedderReady() else { return }
        _ = try? await longTermMemory.backfillUnembedded()
    }

    /// Suspends while MiniLM (or the configured provider) is `.loading`, matching remember.
    /// Missing providers and wait timeouts do not throw — callers degrade to text + warning.
    func awaitQueryEmbedderIfNeeded(memory: MemoryOrchestrator) async {
        guard !noEmbedder else { return }
        let stats = await memory.runtimeStats()
        guard stats.vectorSearchEnabled, await memory.shouldDeferRememberUntilEmbedderReady() else {
            return
        }
        try? await Self.awaitRememberReady(
            memory: memory,
            timeout: .seconds(BrokerLimits.embedderReadyWaitSeconds)
        )
    }

    /// Compact JSON warning when hybrid was requested but some or all stores used text.
    package static func retrievalDowngradeWarning(
        _ diagnostics: RAGContext.Diagnostics
    ) -> String? {
        retrievalDowngradeWarning(.uniform(diagnostics))
    }

    /// Compact JSON warning for layered recall, including mixed/unavailable lanes.
    package static func retrievalDowngradeWarning(
        _ diagnostics: LayeredRecall.LaneDiagnostics
    ) -> String? {
        switch diagnostics {
        case .unavailable:
            return nil
        case .mixed(let requested):
            guard isHybrid(requested) else { return nil }
            return "WARNING: hybrid requested, some memory stores used text"
        case .uniform(let diagnostics):
            guard isHybrid(diagnostics.requestedMode) else { return nil }
            guard diagnostics.effectiveMode == .textOnly else { return nil }
            let reason: String
            switch diagnostics.queryEmbeddingState {
            case .timeout:
                reason = "embedder timeout"
            case .circuitOpen:
                reason = "embedder circuit open"
            case .failed:
                reason = "embedder failed"
            case .vectorDisabled:
                reason = "vector search disabled"
            case .vectorsRebuilding:
                reason = "vectors re-embedding for a new model"
            case .available:
                reason = "vector search timed out"
            case .noEmbedder, .notRequested:
                reason = "embedder missing"
            }
            return "WARNING: hybrid requested, \(reason), used text"
        }
    }

    private static func isHybrid(_ mode: SearchMode) -> Bool {
        if case .hybrid = mode { return true }
        return false
    }
}
