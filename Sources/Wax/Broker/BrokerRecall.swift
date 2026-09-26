import Foundation

/// Broker-owned recall, MCP search, and memory_search pipeline: fetch + merge + pack.
///
/// Recall: session snapshot → multi-horizon fetch → merge → scope select → pack.
/// Search: the same snapshot and identity fence, with the MCP search rank law
/// (score desc, working before durable on ties).
/// MemorySearch: resolved session scope in; snapshot → horizon fetch → the
/// memory_search rank law (+0.25 working / +0.10 durable, episodic recency) →
/// session fence → pack. The two search rank laws stay distinct entry points,
/// never a rank-law flag. `RecallPresent` stays a separate module for wire
/// rendering; impression side effects stay with the broker.
///
/// Interface invariants (caller-enforced, documented here):
/// - Caller guarantees remember drain. The module takes no lock; call the
///   recall/search entry under `commandMutex` after teardown serialization,
///   exactly as `handle` routes non-drain commands today. Concurrent `remember`
///   during retrieval degrades to stale reads, never corruption.
/// - Recall/search callers run the embedder wait first. memory_search relies on
///   in-lane degradation instead (admission takes no embedder wait); the module
///   itself never waits on readiness in any entry point.
package enum BrokerRecall {
    /// Live handles. The module snapshots sessions once per retrieval behind
    /// the seam; callers never build `LayeredRecall.Stores` for this path.
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

    /// Packed MCP search. `payload` is wire-ready; `sessionHits` exist so the
    /// caller can record retrieval hits (a broker side effect).
    package struct PackedSearch: Sendable {
        package var payload: AgentBrokerValue
        package var hits: [MemoryOrchestrator.MemorySearchHit]
        package var sessionHits: [MemoryOrchestrator.MemorySearchHit]
        package var requestedMode: SearchMode
        package var effectiveMode: SearchMode
        package var queryEmbeddingState: RAGContext.QueryEmbeddingState

        package init(
            payload: AgentBrokerValue,
            hits: [MemoryOrchestrator.MemorySearchHit],
            sessionHits: [MemoryOrchestrator.MemorySearchHit],
            requestedMode: SearchMode,
            effectiveMode: SearchMode,
            queryEmbeddingState: RAGContext.QueryEmbeddingState
        ) {
            self.payload = payload
            self.hits = hits
            self.sessionHits = sessionHits
            self.requestedMode = requestedMode
            self.effectiveMode = effectiveMode
            self.queryEmbeddingState = queryEmbeddingState
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
            memoryTypes: command.memoryTypes,
            includeWorking: command.includeWorking
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

    /// MCP search fetch + merge + pack. Rank law is score desc, working before
    /// durable on ties, then frameId desc — not `LayeredRecall.search`.
    package static func search(
        _ command: BrokerCommand.Search,
        in environment: Environment
    ) async throws -> PackedSearch {
        let stores = makeStores(
            snapshot: environment.sessions.live,
            longTermMemory: environment.longTermMemory,
            endedSessions: environment.endedSessions,
            preview: environment.preview,
            canonicalFrameID: environment.canonicalFrameID,
            nowMs: environment.nowMs
        )
        let query = command.query
        let mode = command.mode
        let topK = command.topK
        let parsedFilters = command.filters

        let sessionExecution: MemoryOrchestrator.SearchExecution
        let sessionHits: [MemoryOrchestrator.MemorySearchHit]
        if let sessionID = parsedFilters.sessionId,
           let working = stores.workingLane(sessionID)?.memory {
            sessionExecution = try await working.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: parsedFilters.frameFilter,
                timeRange: parsedFilters.timeRange
            )
            sessionHits = sessionExecution.hits
        } else if parsedFilters.sessionId != nil {
            sessionExecution = MemoryOrchestrator.SearchExecution(
                hits: [],
                diagnostics: .text(requested: mode, embedding: .notRequested)
            )
            sessionHits = []
        } else {
            sessionExecution = try await stores.longTermMemory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: parsedFilters.frameFilter,
                timeRange: parsedFilters.timeRange
            )
            sessionHits = []
        }

        let execution: MemoryOrchestrator.SearchExecution
        if parsedFilters.sessionId == nil {
            execution = sessionExecution
        } else {
            let identity = stores.inferWriteScope(parsedFilters.sessionId, nil)
            let durableFilter = LayeredRecall.frameFilterForScopedRetrieval(
                base: parsedFilters.frameFilter,
                scope: .project,
                identity: identity
            )
            var durableExecution = try await stores.longTermMemory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: durableFilter,
                timeRange: parsedFilters.timeRange
            )
            // `frameFilterForScopedRetrieval` no-ops on empty identity; still drop
            // stamped foreign durable so session-scoped search matches recall.
            durableExecution.hits = durableExecution.hits.filter {
                allowsDurableSearchHit(metadata: $0.metadata, identity: identity)
            }
            execution = mergeSearchExecutions(
                working: sessionExecution,
                durable: durableExecution,
                topK: topK
            )
        }
        return packSearch(
            command: command,
            execution: execution,
            sessionHits: sessionHits,
            preview: environment.preview
        )
    }

    /// Packed memory_search. `payload` is wire-ready; `hits` are fenced and
    /// exist so the caller can record working-lane retrieval hits (a broker
    /// side effect, outside the module).
    package struct PackedMemorySearch: Sendable {
        package var payload: AgentBrokerValue
        package var hits: [LayeredRecall.Hit]

        package init(payload: AgentBrokerValue, hits: [LayeredRecall.Hit]) {
            self.payload = payload
            self.hits = hits
        }
    }

    /// memory_search fetch + merge + fence + pack. The caller resolves the
    /// session scope (explicit id, sole-live inference, or durable-only
    /// fallback) and passes it in; the module snapshots once and never
    /// re-resolves, so fetch and fence cannot skew. Only `query`/`mode`/`topK`
    /// are read from `command`; the wire session/horizons are ignored in
    /// favor of the resolved arguments.
    package static func memorySearch(
        _ command: BrokerCommand.MemorySearch,
        sessionID: UUID?,
        horizons: HorizonSet,
        in environment: Environment
    ) async throws -> PackedMemorySearch {
        let stores = makeStores(
            snapshot: environment.sessions.live,
            longTermMemory: environment.longTermMemory,
            endedSessions: environment.endedSessions,
            preview: environment.preview,
            canonicalFrameID: environment.canonicalFrameID,
            nowMs: environment.nowMs
        )
        var hits: [LayeredRecall.Hit] = []
        if !horizons.isEmpty {
            let identity = try MemorySearchIdentity.make(sessionID: sessionID, horizons: horizons)
            hits = try await LayeredRecall.search(
                request: LayeredRecall.SearchRequest(
                    query: command.query,
                    mode: command.mode,
                    topK: command.topK,
                    identity: identity
                ),
                stores: stores
            )
            if sessionID != nil {
                let fence = stores.inferWriteScope(sessionID, nil)
                hits = hits.filter { allowsMemorySearchHit($0, identity: fence) }
            }
        }
        return packMemorySearch(command: command, hits: hits, nowMs: environment.nowMs())
    }

    /// memory_search fence: working-lane hits are always kept; durable and
    /// episodic follow the durable stamp rule.
    package static func allowsMemorySearchHit(
        _ hit: LayeredRecall.Hit,
        identity: LayeredRecall.Identity
    ) -> Bool {
        if hit.horizon == .working { return true }
        return allowsDurableSearchHit(metadata: hit.metadata, identity: identity)
    }

    /// Shared `Stores` construction behind the seam. All three entries build
    /// through this function so the snapshot cannot drift.
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
                    memory: state.memory,
                    conversationID: state.manifest.conversationID
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

        let verbose: Bool
        switch command.verbosity {
        case .compact:
            verbose = false
        case .verbose:
            verbose = true
        }
        let staleFlags = RecallPresent.staleHints(for: result.hits)
        let results: [AgentBrokerValue] = result.hits.enumerated().map { index, hit in
            RecallPresent.renderRecallHit(
                hit,
                rank: index + 1,
                verbose: verbose,
                nowMs: nowMs,
                staleHint: staleFlags[index]
            )
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
            "collapsed": .from(result.collapsed),
            "summary": .string(RecallPresent.summary(for: result.hits)),
            "display_text": .string(lines.joined(separator: "\n")),
        ]
        if let warning = AgentBrokerService.retrievalDowngradeWarning(result.diagnostics) {
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

    /// Unresolved identity keeps unstamped durable and drops stamped foreign.
    /// Resolved identity is exact `wax.project` / `wax.repo`.
    package static func allowsDurableSearchHit(
        metadata: [String: String],
        identity: LayeredRecall.Identity
    ) -> Bool {
        if identity.project == nil && identity.repo == nil {
            return !hasExplicitProjectOrRepoStamp(metadata)
        }
        return LayeredRecall.metadataMatchesScopedRetrieval(metadata, identity: identity)
    }

    /// Session-scoped corpus fence. Unresolved identity still keeps live
    /// `activeSession` rows visible; other origins follow the durable stamp rule.
    package static func allowsCorpusSearchHit(
        _ hit: BrokerCorpusMergeHit,
        identity: LayeredRecall.Identity
    ) -> Bool {
        if identity.project != nil || identity.repo != nil {
            return LayeredRecall.metadataMatchesScopedRetrieval(hit.metadata, identity: identity)
        }
        if hit.origin == .activeSession {
            return true
        }
        return allowsDurableSearchHit(metadata: hit.metadata, identity: identity)
    }

    package static func hasExplicitProjectOrRepoStamp(_ metadata: [String: String]) -> Bool {
        let project = metadata[MemoryMetadataKeys.project]
        let repo = metadata[MemoryMetadataKeys.repo]
        return (project.map { !$0.isEmpty } ?? false) || (repo.map { !$0.isEmpty } ?? false)
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
        let diagnostics: RAGContext.Diagnostics
        switch (working.effectiveMode, durable.effectiveMode) {
        case (.textOnly, _), (_, .textOnly):
            diagnostics = .text(
                requested: working.requestedMode,
                embedding: worseQueryEmbeddingState(
                    working.queryEmbeddingState,
                    durable.queryEmbeddingState
                )
            )
        default:
            diagnostics = .vector(
                requested: working.requestedMode,
                effective: working.effectiveMode
            )
        }
        return MemoryOrchestrator.SearchExecution(
            hits: tagged.prefix(max(1, topK)).map(\.0),
            diagnostics: diagnostics
        )
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

    private static func packMemorySearch(
        command: BrokerCommand.MemorySearch,
        hits: [LayeredRecall.Hit],
        nowMs: Int64
    ) -> PackedMemorySearch {
        let rows = hits.map { RecallPresent.renderLayeredMemoryHit($0, nowMs: nowMs) }
        let text = rows.isEmpty ? "No results." : rows.map(\.debugJSONString).joined(separator: "\n")
        return PackedMemorySearch(
            payload: .object([
                "query": .string(command.query),
                "topK": .from(command.topK),
                "results": .array(rows),
                "display_text": .string(text),
            ]),
            hits: hits
        )
    }

    private static func packSearch(
        command: BrokerCommand.Search,
        execution: MemoryOrchestrator.SearchExecution,
        sessionHits: [MemoryOrchestrator.MemorySearchHit],
        preview: @Sendable (String?) -> String
    ) -> PackedSearch {
        let query = command.query
        let topK = command.topK
        let parsedFilters = command.filters
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
            "applied_filters": parsedFilters.summary,
            "time_range_requested": .from(parsedFilters.timeRange != nil),
            "time_range_applied": .from(parsedFilters.timeRange != nil),
            "results": .array(rows),
            "display_text": .string(text),
        ]
        if let warning = AgentBrokerService.retrievalDowngradeWarning(execution.diagnostics) {
            payload["warning"] = .string(warning)
        }
        return PackedSearch(
            payload: .object(payload),
            hits: execution.hits,
            sessionHits: sessionHits,
            requestedMode: execution.requestedMode,
            effectiveMode: execution.effectiveMode,
            queryEmbeddingState: execution.queryEmbeddingState
        )
    }
}
