import Foundation
import WaxCore

extension LayeredRecall {
    /// True when working or durable already has a frame retrieval would keep
    /// for this named project. Metadata only — do not load bodies. Store-wide
    /// `frameCount` is the wrong probe.
    private static func projectLaneOccupied(
        identity: Identity,
        request: RecallRequest,
        stores: Stores
    ) async -> Bool {
        if let sessionID = request.sessionID, let working = stores.workingLane(sessionID) {
            if await storeHasProjectLaneFrames(working.memory, identity: identity) {
                return true
            }
        }
        return await storeHasProjectLaneFrames(stores.longTermMemory, identity: identity)
    }

    private static func storeHasProjectLaneFrames(
        _ memory: MemoryOrchestrator,
        identity: Identity
    ) async -> Bool {
        let metas = await memory.wax.frameMetas()
        for meta in metas {
            guard meta.status == .active, meta.supersededBy == nil, meta.role == .document else {
                continue
            }
            if metadataMatchesScopedRetrieval(meta.metadata?.entries ?? [:], identity: identity) {
                return true
            }
        }
        return false
    }

    /// Git ancestry for the hits about to be merged. Call once per recall, before `mergeHits`.
    private static func resolvedCheckoutRelations(
        for hits: [Hit],
        live: GitCheckoutSnapshot,
        repoRootPath: String?
    ) -> [String: OnThisTree] {
        MemorySemantics.checkoutRelations(
            storedSHAs: distinctStoredGitSHAs(in: hits),
            live: live,
            repoRootPath: repoRootPath
        )
    }

    private static func distinctStoredGitSHAs(in hits: [Hit]) -> [String] {
        var seen = Set<String>()
        var stored: [String] = []
        for hit in hits {
            guard let sha = hit.metadata[MemoryMetadataKeys.gitSHA],
                  !sha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(sha).inserted else {
                continue
            }
            stored.append(sha)
        }
        return stored
    }

    package static func recall(
        request: RecallRequest,
        stores: Stores
    ) async throws -> RecallResult {
        var fetchRequest = request
        let personLane = request.scope == .global && request.memoryTypes == [.userPreference]
        fetchRequest.searchTopK = personLane
            ? retrievalTopKForGlobalPersonLane(requested: request.searchTopK)
            : retrievalTopK(requested: request.searchTopK)
        let lanes = try await fetchLanes(
            request: fetchRequest,
            stores: stores,
            horizons: fetchRequest.fetchHorizons
        )
        let identity = lanes.identity
        let liveCheckout = MemorySemantics.snapshotGitCheckout(startingAt: request.clientCWD)
        let repoRootPath = request.clientCWD.flatMap {
            MemorySemantics.inferScopeContext(currentDirectoryPath: $0).repoRootPath
        }

        let typedWorking = filterHitsByMemoryTypes(lanes.working, types: request.memoryTypes)
        let typedDurable = filterHitsByMemoryTypes(lanes.durable, types: request.memoryTypes)
        let merged: [Hit]
        if request.scope == .session {
            merged = Array(typedWorking.prefix(request.limit))
        } else if request.scope == .project {
            // Filter before merge so foreign ranks cannot consume the result budget.
            let ownWorking = Self.filterForeignTaskState(typedWorking, sessionID: request.sessionID)
            let ownDurable = Self.filterForeignTaskState(typedDurable, sessionID: request.sessionID)
            let scopedSession = Self.filterHitsByProject(
                ownWorking,
                project: identity.project,
                repo: identity.repo
            )
            let scopedDurable = Self.filterHitsByProject(
                ownDurable,
                project: identity.project,
                repo: identity.repo
            )
            merged = mergeHits(
                sessionHits: scopedSession,
                durableHits: scopedDurable,
                limit: request.limit,
                nowMs: stores.nowMs(),
                query: request.query,
                liveCheckout: liveCheckout,
                relations: resolvedCheckoutRelations(
                    for: scopedSession + scopedDurable,
                    live: liveCheckout,
                    repoRootPath: repoRootPath
                )
            )
        } else {
            // Global changes the project boundary, not query or filter matching.
            // Person-lane still drops other-project prefs when identity is resolved.
            var personLaneWorking = filterHitsForGlobalPersonLane(
                typedWorking,
                memoryTypes: request.memoryTypes,
                identity: identity
            )
            var personLaneDurable = filterHitsForGlobalPersonLane(
                typedDurable,
                memoryTypes: request.memoryTypes,
                identity: identity
            )
            if personLane, identity.project != nil || identity.repo != nil {
                // Type-only global retrieval can spend the window on foreign prefs.
                // A project-scoped typed fetch keeps current-project prefs visible
                // the same way single-type retrieval keeps the person-lane hit.
                var scopedRequest = request
                scopedRequest.identity = .project(workingSessionID: request.sessionID)
                scopedRequest.searchTopK = retrievalTopK(requested: request.searchTopK)
                let scopedLanes = try await fetchLanes(request: scopedRequest, stores: stores)
                personLaneWorking.append(contentsOf: filterHitsByMemoryTypes(
                    scopedLanes.working,
                    types: request.memoryTypes
                ))
                personLaneDurable.append(contentsOf: filterHitsByMemoryTypes(
                    scopedLanes.durable,
                    types: request.memoryTypes
                ))
            }
            let searched = mergeHits(
                sessionHits: personLaneWorking,
                durableHits: personLaneDurable,
                limit: request.limit,
                nowMs: stores.nowMs(),
                query: request.query,
                liveCheckout: liveCheckout,
                relations: resolvedCheckoutRelations(
                    for: personLaneWorking + personLaneDurable,
                    live: liveCheckout,
                    repoRootPath: repoRootPath
                )
            )
            if personLane {
                let cardHits = await OwnerCard.hits(
                    from: stores.longTermMemory,
                    nowMs: stores.nowMs(),
                    preview: stores.preview
                )
                if let card = OwnerCard.collapsedHit(from: cardHits, preview: stores.preview) {
                    // Card leads; leftover prefs still fill the window.
                    let rest = searched.filter { hit in
                        !hit.flags.contains(.ownerCard)
                            && !OwnerCard.matchesCompiledSlot(text: hit.text, metadata: hit.metadata)
                    }
                    merged = Array(([card] + rest).prefix(request.limit))
                } else {
                    merged = searched
                }
            } else {
                merged = searched
            }
        }

        let selected = selectHits(merged: merged, scope: request.scope, identity: identity)
        var projectMiss = selected.projectMiss
        var scopeMissMessage = selected.scopeMissMessage
        if request.scope == .project,
           selected.hits.isEmpty,
           projectMiss,
           identity.project != nil || identity.repo != nil,
           await projectLaneOccupied(identity: identity, request: request, stores: stores) {
            // Query miss in an occupied project is not an empty lane.
            projectMiss = false
            scopeMissMessage = nil
        }
        let keptHits = Array(selected.hits.prefix(request.limit))
        let laneDiagnostics = combinedLaneDiagnostics(
            working: lanes.workingExecution,
            durable: lanes.durableExecution
        )

        return RecallResult(
            hits: keptHits,
            scope: request.scope,
            identity: identity,
            projectMiss: projectMiss,
            scopeMissMessage: scopeMissMessage,
            scopeDropped: selected.scopeDropped,
            diagnostics: laneDiagnostics,
            searchTopK: request.searchTopK,
            retrievalTopK: fetchRequest.searchTopK,
            limit: request.limit,
            collapsed: collapsedTotal(in: keptHits)
        )
    }

    private static func combinedLaneDiagnostics(
        working: MemoryOrchestrator.RecallExecution?,
        durable: MemoryOrchestrator.RecallExecution?
    ) -> LaneDiagnostics {
        switch (working, durable) {
        case let (working?, durable?):
            if working.effectiveMode == durable.effectiveMode,
               working.queryEmbeddingState == durable.queryEmbeddingState {
                return .uniform(working.diagnostics)
            }
            return .mixed(requested: working.requestedMode)
        case let (working?, nil):
            return .uniform(working.diagnostics)
        case let (nil, durable?):
            return .uniform(durable.diagnostics)
        case (nil, nil):
            return .unavailable
        }
    }

    /// Horizon fetch for the memory_search rank law. Only `BrokerRecall`
    /// invokes this in Sources; tests pin fetch shape directly.
    package static func search(
        request: SearchRequest,
        stores: Stores
    ) async throws -> [Hit] {
        var hits: [Hit] = []

        if let sessionID = request.identity.workingSessionID,
           let lane = stores.workingLane(sessionID) {
            let execution = try await lane.memory.searchExecution(
                query: request.query,
                mode: request.mode,
                topK: max(1, min(request.topK, 6)),
                frameFilter: nil,
                timeRange: nil
            )
            for result in execution.hits {
                guard let canonicalFrameID = await stores.canonicalFrameID(result.frameId, lane.memory) else {
                    continue
                }
                hits.append(
                    Hit(
                        id: .working(sessionID: sessionID, frameID: canonicalFrameID),
                        agentID: lane.agentID,
                        runID: lane.runID,
                        score: result.score + 0.25,
                        text: stores.preview(result.previewText),
                        preview: stores.preview(result.previewText),
                        metadata: result.metadata,
                        explanations: ["current session"] + result.explanations,
                        timestampMs: result.metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init) ?? 0,
                        sources: result.sources
                    )
                )
            }
        }

        if request.horizons.contains(.durable) {
            let execution = try await stores.longTermMemory.searchExecution(
                query: request.query,
                mode: request.mode,
                topK: max(1, min(request.topK, 8)),
                frameFilter: nil,
                timeRange: nil
            )
            let nowMs = stores.nowMs()
            for result in execution.hits {
                guard MemoryRetention.isVisibleInDefaultRecall(
                    metadata: result.metadata,
                    nowMs: nowMs,
                    query: request.query,
                    mode: request.mode
                ) else { continue }
                guard let canonicalFrameID = await stores.canonicalFrameID(
                    result.frameId,
                    stores.longTermMemory
                ) else {
                    continue
                }
                hits.append(
                    Hit(
                        id: .durable(frameID: canonicalFrameID),
                        score: result.score + 0.10,
                        text: stores.preview(result.previewText),
                        preview: stores.preview(result.previewText),
                        metadata: result.metadata,
                        explanations: ["durable memory"] + result.explanations,
                        timestampMs: result.metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init) ?? 0,
                        sources: result.sources
                    )
                )
            }
        }

        if request.horizons.contains(.episodic) {
            let currentAgentID = request.sessionID.flatMap { stores.workingLane($0)?.agentID }
            let scopedManifests = episodicManifests(
                from: try stores.endedSessions.listManifests(),
                currentSessionID: request.sessionID,
                currentAgentID: currentAgentID
            )
            .prefix(6)

            for manifest in scopedManifests {
                let laneHits = try await stores.endedSessions.search(
                    EndedSessionSearchQuery(
                        manifest: manifest,
                        query: request.query,
                        mode: request.mode,
                        topK: max(1, min(3, request.topK))
                    )
                )
                let ageMs: Int64 = max(0, stores.nowMs() - manifest.updatedAtMs)
                let recencyBoost: Float = ageMs < Int64(7 * 24 * 60 * 60 * 1000) ? 0.15 : 0.05
                for laneHit in laneHits {
                    guard let canonicalFrameID = laneHit.canonicalFrameID else { continue }
                    var explanations = ["recent session episode", "agent \(manifest.agentID)"]
                    if let recallCount = laneHit.recallCount, let uniqueQueryCount = laneHit.uniqueQueryCount {
                        explanations.append("recalled \(recallCount)x across \(uniqueQueryCount) queries")
                    }
                    explanations.append(contentsOf: laneHit.explanations)
                    hits.append(
                        Hit(
                            id: .episodic(sessionID: manifest.sessionID, frameID: canonicalFrameID),
                            agentID: manifest.agentID,
                            runID: manifest.runID,
                            score: laneHit.score + recencyBoost,
                            text: stores.preview(laneHit.previewText),
                            preview: stores.preview(laneHit.previewText),
                            metadata: laneHit.metadata,
                            explanations: explanations,
                            timestampMs: laneHit.metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init) ?? 0,
                            sources: []
                        )
                    )
                }
            }
        }

        let deduped = Dictionary(hits.map { ($0.reference, $0) }, uniquingKeysWith: { current, candidate in
            candidate.score > current.score ? candidate : current
        }).values

        return Array(
            deduped.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
                return lhs.reference < rhs.reference
            }.prefix(request.topK)
        )
    }
}
