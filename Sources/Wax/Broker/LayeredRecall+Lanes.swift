import Foundation
import WaxCore

extension LayeredRecall {
    package static func hit(from item: RAGContext.Item, horizon: Horizon, sessionID: UUID) -> Hit {
        hit(from: item, id: MemoryID.make(horizon: horizon, sessionID: sessionID, frameID: item.frameId))
    }

    package static func hit(from item: RAGContext.Item) -> Hit {
        hit(from: item, id: .durable(frameID: item.frameId))
    }

    package static func hit(from item: RAGContext.Item, id: MemoryID) -> Hit {
        // FTS5 snippet() wraps matched tokens in private-use markers
        // (FTS5SearchEngine.snippetOpenMarker/CloseMarker). Snippet-kind
        // text carries those markers; expanded/surrogate text is full-frame
        // and must keep legitimate user brackets. Dehighlight snippets only,
        // matching the agentFacingPreview path used for preview closures.
        let text: String
        if item.kind == .snippet {
            text = UnifiedRanking.dehighlightedPreviewText(item.text)
        } else {
            text = item.text
        }
        return Hit(
            id: id,
            score: item.score,
            text: text,
            preview: MemorySemantics.summarizeCandidate(text, maxLength: 180),
            metadata: item.metadata,
            explanations: item.explanations,
            timestampMs: item.metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init) ?? 0,
            kind: item.kind,
            sources: item.sources
        )
    }

    /// Bridge for callers that still speak `RAGContext.Item` (tests / gradual migrate).
    package static func mergeRecallItems(
        sessionItems: [RAGContext.Item],
        durableItems: [RAGContext.Item],
        limit: Int,
        nowMs: Int64 = 0
    ) -> [RAGContext.Item] {
        let sessionHits = sessionItems.map {
            hit(from: $0, horizon: .working, sessionID: UUID())
        }
        let durableHits = durableItems.map { hit(from: $0) }
        return mergeHits(
            sessionHits: sessionHits,
            durableHits: durableHits,
            limit: limit,
            nowMs: nowMs
        ).map { hit in
            RAGContext.Item(
                kind: hit.kind,
                frameId: hit.frameID,
                score: hit.score,
                sources: hit.sources.isEmpty ? [.unknown] : hit.sources,
                text: hit.text,
                metadata: hit.metadata,
                explanations: hit.explanations
            )
        }
    }

    package static func filterRecallItemsByProject(
        _ items: [RAGContext.Item],
        project: String?,
        repo: String?
    ) -> [RAGContext.Item] {
        let hits = items.map { hit(from: $0) }
        let filtered = filterHitsByProject(hits, project: project, repo: repo)
        let allowed = Set(filtered.map(\.frameID))
        return items.filter { allowed.contains($0.frameId) }
    }

    package static func fetchLanes(
        request: RecallRequest,
        stores: Stores,
        horizons: HorizonSet = [.working, .durable],
        canonicalizeFrameIDs: Bool = false,
        episodicTopK: Int = 2
    ) async throws -> HorizonLanes {
        let working: WorkingLane? = request.sessionID.flatMap { stores.workingLane($0) }
        let inferred = stores.inferWriteScope(request.sessionID, request.clientCWD)
        let identity = resolveIdentity(
            explicitProject: request.explicitProject,
            explicitRepo: request.explicitRepo,
            sessionProject: working?.project,
            sessionRepo: working?.repo,
            inferred: inferred
        )

        let topK = max(1, request.searchTopK)
        // A non-nil empty context intentionally disables the orchestrator's
        // configured project fallback for global recall.
        let rankingScope = request.scope == .global
            ? MemoryScopeContext()
            : MemoryScopeContext(repoName: identity.repo, projectName: identity.project)
        // Project scope injects identity into the frame filter so foreign hits
        // cannot crowd the lane. Global and session leave the caller filter alone.
        // A single memory_type is also a retrieval hard-filter so person-lane
        // recall cannot lose to higher-scoring lessons at merge time.
        let scopedFrameFilter = Self.frameFilterForMemoryTypes(
            base: Self.frameFilterForScopedRetrieval(
                base: request.frameFilter,
                scope: request.scope,
                identity: identity
            ),
            types: request.memoryTypes
        )

        var sessionHits: [Hit] = []
        var sessionExecution: MemoryOrchestrator.RecallExecution?
        if horizons.contains(.working), let working {
            let execution = try await working.memory.recallExecution(
                query: request.query,
                mode: request.mode,
                frameFilter: scopedFrameFilter,
                timeRange: request.timeRange,
                topK: topK,
                scopeContext: rankingScope
            )
            sessionExecution = execution
            sessionHits = execution.context.items.map {
                hit(from: $0, horizon: .working, sessionID: working.sessionID)
            }
            sessionHits = sessionHits.map { hit in
                var copy = hit
                copy.agentID = working.agentID
                copy.runID = working.runID
                copy.conversationID = working.conversationID
                return copy
            }
            if canonicalizeFrameIDs {
                sessionHits = await canonicalizeHits(sessionHits, memory: working.memory, stores: stores)
            }
        }

        var durableHits: [Hit] = []
        var durableExecution: MemoryOrchestrator.RecallExecution?
        if request.scope != .session, horizons.contains(.durable) {
            let execution = try await stores.longTermMemory.recallExecution(
                query: request.query,
                mode: request.mode,
                frameFilter: scopedFrameFilter,
                timeRange: request.timeRange,
                topK: topK,
                scopeContext: rankingScope
            )
            durableExecution = execution
            durableHits = visibleDurableHits(from: execution, request: request, nowMs: stores.nowMs())
            if canonicalizeFrameIDs {
                durableHits = await canonicalizeHits(
                    durableHits,
                    memory: stores.longTermMemory,
                    stores: stores
                )
            }
        }

        var episodicHits: [Hit] = []
        if horizons.contains(.episodic) {
            let selected = episodicManifests(
                from: try stores.endedSessions.listManifests(),
                currentSessionID: request.sessionID,
                currentAgentID: working?.agentID
            )
            for manifest in selected {
                let hits = try await stores.endedSessions.recall(
                    EndedSessionRecallQuery(
                        manifest: manifest,
                        query: request.query,
                        mode: request.mode ?? .hybrid(),
                        topK: max(1, episodicTopK),
                        frameFilter: scopedFrameFilter
                    )
                )
                episodicHits.append(contentsOf: hits)
            }
        }

        return HorizonLanes(
            working: sessionHits,
            episodic: episodicHits,
            durable: durableHits,
            identity: identity,
            workingExecution: sessionExecution,
            durableExecution: durableExecution
        )
    }

    private static func visibleDurableHits(
        from execution: MemoryOrchestrator.RecallExecution,
        request: RecallRequest,
        nowMs: Int64
    ) -> [Hit] {
        execution.context.items.map { hit(from: $0) }.filter { hit in
            MemoryRetention.isVisibleInDefaultRecall(
                metadata: hit.metadata,
                nowMs: nowMs,
                query: request.query,
                mode: request.mode
            )
        }
    }

    private static func canonicalizeHits(
        _ hits: [Hit],
        memory: MemoryOrchestrator,
        stores: Stores
    ) async -> [Hit] {
        var canonicalized: [Hit] = []
        canonicalized.reserveCapacity(hits.count)
        for hit in hits {
            var copy = hit
            if let canonical = await stores.canonicalFrameID(hit.frameID, memory) {
                copy.id = copy.id.replacingFrameID(canonical)
            }
            canonicalized.append(copy)
        }
        return canonicalized
    }
}
