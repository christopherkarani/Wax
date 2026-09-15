import Foundation

/// Broker-owned recall pipeline: fetch + merge + pack behind one seam.
///
/// One entry point spans session snapshot → multi-horizon fetch → merge →
/// scope select → wire-ready pack. `RecallPresent` stays a separate module for
/// wire rendering; impression side effects stay with the broker.
///
/// Interface invariants (caller-enforced, documented here):
/// - Caller guarantees remember drain. The module takes no lock; call the
///   recall entry under `commandMutex` after teardown serialization, exactly
///   as `handle` routes non-drain commands today. Concurrent `remember` during
///   recall degrades to stale reads, never corruption.
/// - Caller runs the embedder wait first. The module never waits on readiness;
///   an unready embedder degrades inside the orchestrator lanes and surfaces
///   via the effective-mode diagnostics in the pack.
package enum BrokerRecall {
    /// Live handles. The module snapshots sessions once per recall behind the
    /// seam; callers never build `LayeredRecall.Stores` for this path.
    package struct Environment: Sendable {
        package var longTermMemory: MemoryOrchestrator
        package var sessions: VirtualSessionStore
        package var endedSessions: DiskEndedSessionStore
        package var preview: @Sendable (String?) -> String
        package var canonicalFrameID: @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?
        package var nowMs: @Sendable () -> Int64

        package init(
            longTermMemory: MemoryOrchestrator,
            sessions: VirtualSessionStore,
            endedSessions: DiskEndedSessionStore,
            preview: @escaping @Sendable (String?) -> String,
            canonicalFrameID: @escaping @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?,
            nowMs: @escaping @Sendable () -> Int64
        ) {
            self.longTermMemory = longTermMemory
            self.sessions = sessions
            self.endedSessions = endedSessions
            self.preview = preview
            self.canonicalFrameID = canonicalFrameID
            self.nowMs = nowMs
        }
    }

    /// Packed outcome. `payload` is wire-ready; `hits` exist so the caller can
    /// record impressions (a broker side effect, outside the module).
    package struct PackedRecall: Sendable {
        package var payload: AgentBrokerValue
        package var hits: [LayeredRecall.Hit]
        package var scope: LayeredRecall.Scope
        package var identity: LayeredRecall.Identity

        package init(
            payload: AgentBrokerValue,
            hits: [LayeredRecall.Hit],
            scope: LayeredRecall.Scope,
            identity: LayeredRecall.Identity
        ) {
            self.payload = payload
            self.hits = hits
            self.scope = scope
            self.identity = identity
        }
    }

    /// The recall path. Single snapshot, fetch, merge, pack.
    package static func recall(
        _ command: BrokerCommand.Recall,
        in environment: Environment
    ) async throws -> PackedRecall {
        let request = LayeredRecall.RecallRequest(
            query: command.query,
            identity: command.identity,
            limit: command.limit,
            searchTopK: command.searchTopK,
            mode: command.mode,
            explicitProject: command.explicitProject,
            explicitRepo: command.explicitRepo,
            clientCWD: command.clientCWD,
            frameFilter: command.filters.frameFilter,
            timeRange: command.filters.timeRange,
            memoryTypes: command.memoryTypes
        )
        // Snapshot acquisition lives inside the module: working-lane lookup
        // and scope inference can never skew from each other.
        let stores = makeStores(
            snapshot: environment.sessions.live,
            longTermMemory: environment.longTermMemory,
            endedSessions: environment.endedSessions,
            preview: environment.preview,
            canonicalFrameID: environment.canonicalFrameID,
            nowMs: environment.nowMs
        )
        let result = try await LayeredRecall.recall(request: request, stores: stores)
        return pack(command: command, result: result, nowMs: environment.nowMs())
    }

    /// Shared `Stores` construction behind the seam. The broker's remaining
    /// layered-search path builds through the same function so the snapshot
    /// discipline cannot drift between callers.
    package static func makeStores(
        snapshot sessionsSnapshot: [UUID: VirtualSessionStore.SessionState],
        longTermMemory: MemoryOrchestrator,
        endedSessions: DiskEndedSessionStore,
        preview: @escaping @Sendable (String?) -> String,
        canonicalFrameID: @escaping @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?,
        nowMs: @escaping @Sendable () -> Int64
    ) -> LayeredRecall.Stores {
        LayeredRecall.Stores(
            longTermMemory: longTermMemory,
            workingLane: { sessionID in
                guard let state = sessionsSnapshot[sessionID] else { return nil }
                return LayeredRecall.WorkingLane(
                    sessionID: sessionID,
                    agentID: state.manifest.agentID,
                    runID: state.manifest.runID,
                    updatedAtMs: state.manifest.updatedAtMs,
                    project: state.manifest.project,
                    repo: state.manifest.repo,
                    memory: state.memory
                )
            },
            inferWriteScope: { sessionID, clientCWD in
                if let sessionID, let state = sessionsSnapshot[sessionID] {
                    let project = state.manifest.project
                    let repo = state.manifest.repo
                    if project != nil || repo != nil {
                        return LayeredRecall.Identity(project: project, repo: repo)
                    }
                }
                if let clientCWD {
                    let inferred = MemorySemantics.inferScopeContext(currentDirectoryPath: clientCWD)
                    return LayeredRecall.Identity(
                        project: inferred.projectName,
                        repo: inferred.repoName
                    )
                }
                return LayeredRecall.Identity(project: nil, repo: nil)
            },
            preview: preview,
            canonicalFrameID: canonicalFrameID,
            endedSessions: endedSessions,
            nowMs: nowMs
        )
    }

    private static func pack(
        command: BrokerCommand.Recall,
        result: LayeredRecall.RecallResult,
        nowMs: Int64
    ) -> PackedRecall {
        let query = command.query
        let limit = command.limit
        let effectiveTopK = command.searchTopK
        let parsedFilters = command.filters

        var lines: [String] = []
        if let scopeMissMessage = result.scopeMissMessage {
            lines.append(scopeMissMessage)
        }
        lines.append(contentsOf: [
            "Query: \(query)",
            "Total tokens: \(result.hits.reduce(0) { $0 + max(1, $1.text.split(whereSeparator: \.isWhitespace).count) })",
            "Results: \(result.hits.count) of \(limit) requested (orchestrator returned \(result.hits.count))",
            "Search controls: requested_mode=\(result.requestedModeSummary) effective_mode=\(result.effectiveModeSummary) query_embedding_state=\(result.queryEmbeddingState) search_top_k=\(effectiveTopK) retrieval_top_k=\(result.retrievalTopK) limit=\(limit) scope=\(result.scope.rawValue)",
        ])
        if let project = result.identity.project {
            lines.append("Resolved project: \(project)")
        }
        if let repo = result.identity.repo {
            lines.append("Resolved repo: \(repo)")
        }
        lines.append("Applied filters: \(parsedFilters.summary.debugJSONString)")
        for (index, hit) in result.hits.enumerated() {
            let kind = RecallPresent.itemKindLabel(hit.kind)
            lines.append("\(index + 1). [\(kind)] frame=\(hit.frameID) score=\(String(format: "%.4f", hit.score)) \(hit.text)")
        }

        let verbose = command.verbosity == "verbose"
        let results: [AgentBrokerValue] = result.hits.enumerated().map { index, hit in
            RecallPresent.renderRecallHit(hit, rank: index + 1, verbose: verbose, nowMs: nowMs)
        }

        var payload: [String: AgentBrokerValue] = [
            "query": .string(query),
            "total_tokens": .from(result.hits.reduce(0) { $0 + max(1, $1.text.split(whereSeparator: \.isWhitespace).count) }),
            "result_count": .from(result.hits.count),
            "limit": .from(limit),
            "search_top_k": .from(effectiveTopK),
            "retrieval_top_k": .from(result.retrievalTopK),
            "requested_mode": .string(result.requestedModeSummary),
            "effective_mode": .string(result.effectiveModeSummary),
            "query_embedding_state": .string(result.queryEmbeddingState),
            "scope": .string(result.scope.rawValue),
            "project": .from(result.identity.project),
            "repo": .from(result.identity.repo),
            "project_miss": .bool(result.projectMiss),
            "applied_filters": parsedFilters.summary,
            "results": .array(results),
            "display_text": .string(lines.joined(separator: "\n")),
        ]
        if let warning = AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: result.requestedModeSummary,
            effectiveMode: result.effectiveModeSummary,
            queryEmbeddingState: result.queryEmbeddingState
        ) {
            payload["warning"] = .string(warning)
        }
        if !verbose {
            payload = RecallPresent.slimCompactRecallEnvelope(payload)
        }
        if let scopeMissMessage = result.scopeMissMessage {
            payload["scope_miss_message"] = .string(scopeMissMessage)
        }
        if result.projectMiss {
            payload["next_action"] = .string("retry explicitly with scope=global")
        }
        return PackedRecall(
            payload: .object(payload),
            hits: result.hits,
            scope: result.scope,
            identity: result.identity
        )
    }

    /// Search-tool outcome. Payload keeps diagnostic `rank`/`frameId` keys.
    /// Working hits are returned so the broker can record impressions.
    package struct PackedSearch: Sendable {
        package var payload: AgentBrokerValue
        package var sessionID: UUID?
        package var workingHits: [MemoryOrchestrator.MemorySearchHit]
    }

    /// Snapshot + fence + merge + pack for the raw `search` tool.
    /// Does not use `LayeredRecall.search` (different topK caps, score boosts, MemoryID).
    package static func search(
        _ command: BrokerCommand.Search,
        identity: LayeredRecall.Identity,
        in environment: Environment
    ) async throws -> PackedSearch {
        let query = command.query
        let mode = command.mode
        let topK = command.topK
        let parsedFilters = command.filters
        let sessionID = parsedFilters.sessionId
        let stores = makeStores(
            snapshot: environment.sessions.live,
            longTermMemory: environment.longTermMemory,
            endedSessions: environment.endedSessions,
            preview: environment.preview,
            canonicalFrameID: environment.canonicalFrameID,
            nowMs: environment.nowMs
        )
        let workingMemory: MemoryOrchestrator
        if let sessionID, let lane = stores.workingLane(sessionID) {
            workingMemory = lane.memory
        } else {
            workingMemory = environment.longTermMemory
        }
        let sessionExecution = try await workingMemory.searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: parsedFilters.frameFilter,
            timeRange: parsedFilters.timeRange
        )
        let execution: MemoryOrchestrator.SearchExecution
        if sessionID == nil {
            execution = sessionExecution
        } else {
            let durableFilter = LayeredRecall.frameFilterForScopedRetrieval(
                base: parsedFilters.frameFilter,
                scope: .project,
                identity: identity
            )
            var durableExecution = try await environment.longTermMemory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: durableFilter,
                timeRange: parsedFilters.timeRange
            )
            durableExecution.hits = durableExecution.hits.filter {
                LayeredRecall.matchesSessionScopedRetrieval(
                    metadata: $0.metadata,
                    identity: identity,
                    isWorking: false
                )
            }
            execution = mergeSearchExecutions(
                working: sessionExecution,
                durable: durableExecution,
                topK: topK
            )
        }
        return PackedSearch(
            payload: packSearchPayload(
                query: query,
                topK: topK,
                filtersSummary: parsedFilters.summary,
                timeRangePresent: parsedFilters.timeRange != nil,
                execution: execution,
                preview: environment.preview
            ),
            sessionID: sessionID,
            workingHits: sessionExecution.hits
        )
    }

    /// Session-scoped search merges the live working store with durable long-term.
    /// Working hits win ties so a just-written session note is not buried.
    /// Frame IDs are not comparable across stores; do not dedupe them.
    package static func mergeSearchExecutions(
        working: MemoryOrchestrator.SearchExecution,
        durable: MemoryOrchestrator.SearchExecution,
        topK: Int
    ) -> MemoryOrchestrator.SearchExecution {
        enum Lane: Equatable {
            case working
            case durable
        }
        var tagged: [(MemoryOrchestrator.MemorySearchHit, Lane)] = working.hits.map { ($0, .working) }
        tagged.append(contentsOf: durable.hits.map { ($0, .durable) })
        tagged.sort { lhs, rhs in
            if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
            if lhs.1 != rhs.1 { return lhs.1 == .working }
            return lhs.0.frameId > rhs.0.frameId
        }
        let effectiveMode: SearchMode
        switch (working.effectiveMode, durable.effectiveMode) {
        case (.textOnly, _), (_, .textOnly):
            effectiveMode = .textOnly
        default:
            effectiveMode = working.effectiveMode
        }
        return MemoryOrchestrator.SearchExecution(
            hits: tagged.prefix(max(1, topK)).map(\.0),
            requestedMode: working.requestedMode,
            effectiveMode: effectiveMode,
            queryEmbeddingState: worseQueryEmbeddingState(
                working.queryEmbeddingState,
                durable.queryEmbeddingState
            )
        )
    }

    package static func packSearchPayload(
        query: String,
        topK: Int,
        filtersSummary: AgentBrokerValue,
        timeRangePresent: Bool,
        execution: MemoryOrchestrator.SearchExecution,
        preview: @Sendable (String?) -> String
    ) -> AgentBrokerValue {
        let rows: [AgentBrokerValue] = execution.hits.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "frameId": .from(hit.frameId),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": .string(preview(hit.previewText)),
                "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
                "explanations": .array(hit.explanations.map(AgentBrokerValue.string)),
            ])
        }
        let text = rows.isEmpty ? "No results." : rows.map(\.debugJSONString).joined(separator: "\n")
        var payload: [String: AgentBrokerValue] = [
            "query": .string(query),
            "topK": .from(topK),
            "requested_mode": .string(execution.requestedMode.diagnosticsSummary),
            "effective_mode": .string(execution.effectiveMode.diagnosticsSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "applied_filters": filtersSummary,
            "time_range_requested": .from(timeRangePresent),
            "time_range_applied": .from(timeRangePresent),
            "results": .array(rows),
            "display_text": .string(text),
        ]
        if let warning = AgentBrokerService.retrievalDowngradeWarning(
            requestedMode: execution.requestedMode.diagnosticsSummary,
            effectiveMode: execution.effectiveMode.diagnosticsSummary,
            queryEmbeddingState: execution.queryEmbeddingState.rawValue
        ) {
            payload["warning"] = .string(warning)
        }
        return .object(payload)
    }

    package static func get(
        reference: MemoryID,
        in environment: Environment
    ) async throws -> LayeredRecall.Hit {
        switch reference {
        case .durable(let frameID):
            let document = try await requireDocument(frameID: frameID, memory: environment.longTermMemory)
            return LayeredRecall.Hit(
                id: .durable(frameID: frameID),
                score: 0,
                text: document.text,
                preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                metadata: document.metadata,
                explanations: ["durable memory"],
                timestampMs: document.timestampMs
            )
        case .working(let sessionID, let frameID), .episodic(let sessionID, let frameID):
            if let state = environment.sessions.live[sessionID] {
                let document = try await requireDocument(frameID: frameID, memory: state.memory)
                return LayeredRecall.Hit(
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
            let document = try await environment.endedSessions.document(
                EndedSessionDocumentQuery(sessionID: sessionID, frameID: frameID)
            )
            return LayeredRecall.Hit(
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

    private static func requireDocument(
        frameID: UInt64,
        memory: MemoryOrchestrator
    ) async throws -> MemoryOrchestrator.CorpusSourceDocument {
        guard let document = try await memory.corpusSourceDocuments().first(where: { $0.frameId == frameID }) else {
            throw BrokerValidationError.invalid("No memory document found for frame_id \(frameID)")
        }
        return document
    }

    private static func worseQueryEmbeddingState(
        _ lhs: RAGContext.QueryEmbeddingState,
        _ rhs: RAGContext.QueryEmbeddingState
    ) -> RAGContext.QueryEmbeddingState {
        func rank(_ state: RAGContext.QueryEmbeddingState) -> Int {
            switch state {
            case .available: return 0
            case .notRequested: return 1
            case .vectorDisabled: return 2
            case .noEmbedder: return 3
            case .failed: return 4
            case .circuitOpen: return 5
            case .timeout: return 6
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}
