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
    /// Each unequal SHA can run `git merge-base` and wait up to 200 ms for it, so the
    /// lookups run on a private queue rather than holding a cooperative thread.
    private static func resolvedCheckoutRelations(
        for hits: [Hit],
        live: GitCheckoutSnapshot,
        repoRootPath: String?
    ) async -> [String: OnThisTree] {
        let storedSHAs = distinctStoredGitSHAs(in: hits)
        return await BlockingWork.run {
            MemorySemantics.checkoutRelations(
                storedSHAs: storedSHAs,
                live: live,
                repoRootPath: repoRootPath
            )
        }
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
        try await prepareRecall(request: request, stores: stores).finish()
    }

    /// The part of `recall` that reads the stores. The ``PreparedRecall/finish()`` that
    /// completes it reads none, so a broker can score with the cross-encoder after it
    /// releases the lock it reads the stores under.
    package static func prepareRecall(
        request: RecallRequest,
        stores: Stores
    ) async throws -> PreparedRecall {
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
        // With a reranker, the merge fills its candidate window, and reranking cuts it to
        // the limit; without one, the merge cuts to the limit itself.
        let stage = rerankStage(for: lanes, stores: stores)
        let mergeLimit = stage.map { max(request.limit, $0.options.candidateCount) } ?? request.limit
        let liveCheckout = MemorySemantics.snapshotGitCheckout(startingAt: request.clientCWD)
        let repoRootPath = request.clientCWD.flatMap {
            MemorySemantics.inferScopeContext(currentDirectoryPath: $0).repoRootPath
        }

        let typedWorking = filterHitsByMemoryTypes(lanes.working, types: request.memoryTypes)
        let typedDurable = filterHitsByMemoryTypes(lanes.durable, types: request.memoryTypes)
        // `window` is the merge at `mergeLimit`; `policyTop` is the merge at the limit.
        let window: [Hit]
        let policyTop: [Hit]
        var ownerCard: Hit?
        if request.scope == .session {
            window = Array(typedWorking.prefix(mergeLimit))
            policyTop = Array(typedWorking.prefix(request.limit))
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
            let relations = await resolvedCheckoutRelations(
                for: scopedSession + scopedDurable,
                live: liveCheckout,
                repoRootPath: repoRootPath
            )
            let nowMs = stores.nowMs()
            func merge(limit: Int) -> [Hit] {
                mergeHits(
                    sessionHits: scopedSession,
                    durableHits: scopedDurable,
                    limit: limit,
                    nowMs: nowMs,
                    query: request.query,
                    liveCheckout: liveCheckout,
                    relations: relations
                )
            }
            window = merge(limit: mergeLimit)
            policyTop = mergeLimit == request.limit ? window : merge(limit: request.limit)
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
            let relations = await resolvedCheckoutRelations(
                for: personLaneWorking + personLaneDurable,
                live: liveCheckout,
                repoRootPath: repoRootPath
            )
            let nowMs = stores.nowMs()
            let working = personLaneWorking
            let durable = personLaneDurable
            func merge(limit: Int) -> [Hit] {
                mergeHits(
                    sessionHits: working,
                    durableHits: durable,
                    limit: limit,
                    nowMs: nowMs,
                    query: request.query,
                    liveCheckout: liveCheckout,
                    relations: relations
                )
            }
            window = merge(limit: mergeLimit)
            policyTop = mergeLimit == request.limit ? window : merge(limit: request.limit)
            if personLane {
                let cardHits = await OwnerCard.hits(
                    from: stores.longTermMemory,
                    nowMs: stores.nowMs(),
                    preview: stores.preview
                )
                ownerCard = OwnerCard.collapsedHit(from: cardHits, preview: stores.preview)
            }
        }

        let outline = PreparedRecall.Outline(
            request: request,
            identity: identity,
            diagnostics: combinedLaneDiagnostics(
                working: lanes.workingExecution,
                durable: lanes.durableExecution
            ),
            retrievalTopK: fetchRequest.searchTopK,
            ownerCard: ownerCard
        )
        // A nonempty window reranks to at least one hit, so the occupied-lane check below,
        // which reads a store, can only be needed when nothing is scored.
        if let stage, request.limit > 0, !window.isEmpty {
            var texts: [MemoryID: String] = [:]
            for hit in window.prefix(stage.options.candidateCount)
            where !hit.flags.contains(.unlandedDemoted) {
                texts[hit.id] = await rerankText(for: hit, stores: stores)
            }
            return PreparedRecall(state: .scoring(PreparedRecall.Scoring(
                outline: outline,
                window: window,
                policyTop: policyTop,
                stage: stage,
                texts: texts
            )))
        }
        let result = await outline.result(merged: window) {
            await projectLaneOccupied(identity: identity, request: request, stores: stores)
        }
        return PreparedRecall(state: .finished(result))
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
            .prefix(maxEpisodicStores)

            for manifest in scopedManifests {
                let laneHits: [EpisodicLaneHit]
                do {
                    laneHits = try await stores.endedSessions.search(
                        EndedSessionSearchQuery(
                            manifest: manifest,
                            query: request.query,
                            mode: request.mode,
                            topK: max(1, min(3, request.topK))
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "episodic search of an ended session store",
                        fallback: "skip that session's episodic hits"
                    )
                    continue
                }
                // The manifest is read from disk, so its time can be anything.
                let ageMs = TimestampAge.elapsedMs(since: manifest.updatedAtMs, nowMs: stores.nowMs())
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
