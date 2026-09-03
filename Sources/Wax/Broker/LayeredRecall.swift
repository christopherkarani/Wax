import Foundation
import WaxCore

/// Broker Layered recall: scope/identity, multi-horizon fetch/merge, project filter.
/// Feeds recall, layered search, and Compact assembly.
/// Does not own Ranking scores, Recall assembly packing, Compact assembly packing,
/// MCP payloads, or session rebind.
package enum LayeredRecall {
    package enum Horizon: String, Sendable {
        case working
        case episodic
        case durable
    }

    package enum Scope: String, Sendable {
        case project
        case session
        case global
    }

    package struct Identity: Sendable, Equatable {
        package var project: String?
        package var repo: String?

        package init(project: String? = nil, repo: String? = nil) {
            self.project = project
            self.repo = repo
        }
    }

    package struct Hit: Sendable, Equatable {
        package var id: MemoryID
        package var agentID: String?
        package var runID: String?
        package var score: Float
        package var text: String
        package var preview: String
        package var metadata: [String: String]
        package var explanations: [String]
        package var timestampMs: Int64
        package var kind: RAGContext.ItemKind
        package var sources: [RAGContext.Source]

        package var reference: String { id.wire }
        package var horizon: Horizon { id.horizon }
        package var sessionID: UUID? { id.sessionID }
        package var frameID: UInt64 { id.frameID }

        package init(
            id: MemoryID,
            agentID: String? = nil,
            runID: String? = nil,
            score: Float,
            text: String,
            preview: String,
            metadata: [String: String],
            explanations: [String],
            timestampMs: Int64,
            kind: RAGContext.ItemKind = .snippet,
            sources: [RAGContext.Source] = []
        ) {
            self.id = id
            self.agentID = agentID
            self.runID = runID
            self.score = score
            self.text = text
            self.preview = preview
            self.metadata = metadata
            self.explanations = explanations
            self.timestampMs = timestampMs
            self.kind = kind
            self.sources = sources
        }
    }

    package typealias MemoryReference = MemoryID

    package struct WorkingLane: Sendable {
        package var sessionID: UUID
        package var agentID: String?
        package var runID: String?
        package var updatedAtMs: Int64
        package var project: String?
        package var repo: String?
        package var memory: MemoryOrchestrator

        package init(
            sessionID: UUID,
            agentID: String?,
            runID: String?,
            updatedAtMs: Int64,
            project: String?,
            repo: String?,
            memory: MemoryOrchestrator
        ) {
            self.sessionID = sessionID
            self.agentID = agentID
            self.runID = runID
            self.updatedAtMs = updatedAtMs
            self.project = project
            self.repo = repo
            self.memory = memory
        }
    }

    /// Coerced tool args; Layered recall owns what the fields mean.
    package struct RecallRequest: Sendable {
        package var query: String
        package var scope: Scope
        package var limit: Int
        package var searchTopK: Int
        package var mode: Memory.RetrievalMode?
        package var sessionID: UUID?
        package var explicitProject: String?
        package var explicitRepo: String?
        package var clientCWD: String?
        package var frameFilter: FrameFilter?
        package var timeRange: SearchTimeRange?

        package init(
            query: String,
            scope: Scope,
            limit: Int,
            searchTopK: Int,
            mode: Memory.RetrievalMode? = nil,
            sessionID: UUID? = nil,
            explicitProject: String? = nil,
            explicitRepo: String? = nil,
            clientCWD: String? = nil,
            frameFilter: FrameFilter? = nil,
            timeRange: SearchTimeRange? = nil
        ) {
            self.query = query
            self.scope = scope
            self.limit = limit
            self.searchTopK = searchTopK
            self.mode = mode
            self.sessionID = sessionID
            self.explicitProject = explicitProject
            self.explicitRepo = explicitRepo
            self.clientCWD = clientCWD
            self.frameFilter = frameFilter
            self.timeRange = timeRange
        }
    }

    package struct SearchRequest: Sendable {
        package var query: String
        package var mode: Memory.RetrievalMode
        package var topK: Int
        package var sessionID: UUID?
        package var horizons: HorizonSet

        package init(
            query: String,
            mode: Memory.RetrievalMode,
            topK: Int,
            sessionID: UUID? = nil,
            horizons: HorizonSet
        ) {
            self.query = query
            self.mode = mode
            self.topK = topK
            self.sessionID = sessionID
            self.horizons = horizons
        }
    }

    package struct ScopeDropped: Sendable, Equatable {
        package struct Entry: Sendable, Equatable {
            package var project: String?
            package var repo: String?
            package var score: Float
            package var preview: String

            package init(project: String?, repo: String?, score: Float, preview: String) {
                self.project = project
                self.repo = repo
                self.score = score
                self.preview = preview
            }
        }

        package var count: Int
        package var top: [Entry]
        package var hint: String

        package init(count: Int = 0, top: [Entry] = [], hint: String = "") {
            self.count = count
            self.top = top
            self.hint = hint
        }

        package static let empty = ScopeDropped()
    }

    package struct RecallResult: Sendable {
        package var hits: [Hit]
        package var scope: Scope
        package var identity: Identity
        package var projectMiss: Bool
        package var scopeMissMessage: String?
        package var scopeDropped: ScopeDropped = .empty
        package var requestedModeSummary: String
        package var effectiveModeSummary: String
        package var queryEmbeddingState: String
        package var searchTopK: Int
        package var limit: Int
    }

    package struct EpisodicLaneHit: Sendable {
        package var frameID: UInt64
        package var score: Float
        package var previewText: String?
        package var metadata: [String: String]
        package var explanations: [String]
        package var canonicalFrameID: UInt64?
        package var recallCount: Int?
        package var uniqueQueryCount: Int?

        package init(
            frameID: UInt64,
            score: Float,
            previewText: String?,
            metadata: [String: String],
            explanations: [String],
            canonicalFrameID: UInt64?,
            recallCount: Int? = nil,
            uniqueQueryCount: Int? = nil
        ) {
            self.frameID = frameID
            self.score = score
            self.previewText = previewText
            self.metadata = metadata
            self.explanations = explanations
            self.canonicalFrameID = canonicalFrameID
            self.recallCount = recallCount
            self.uniqueQueryCount = uniqueQueryCount
        }
    }

    /// Store accessors at the Layered recall seam. Broker supplies these; module owns policy.
    package struct Stores: Sendable {
        package var longTermMemory: MemoryOrchestrator
        package var workingLane: @Sendable (UUID) -> WorkingLane?
        package var inferWriteScope: @Sendable (_ sessionID: UUID?, _ clientCWD: String?) -> Identity
        package var preview: @Sendable (String?) -> String
        package var canonicalFrameID: @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?
        package var endedManifests: @Sendable () throws -> [BrokerSessionManifest]
        package var searchEndedSession: @Sendable (
            _ manifest: BrokerSessionManifest,
            _ query: String,
            _ mode: Memory.RetrievalMode,
            _ topK: Int
        ) async throws -> [EpisodicLaneHit]
        package var recallEndedSession: @Sendable (
            _ manifest: BrokerSessionManifest,
            _ query: String,
            _ mode: Memory.RetrievalMode,
            _ topK: Int,
            _ frameFilter: FrameFilter?
        ) async throws -> [Hit]
        package var nowMs: @Sendable () -> Int64

        package init(
            longTermMemory: MemoryOrchestrator,
            workingLane: @escaping @Sendable (UUID) -> WorkingLane?,
            inferWriteScope: @escaping @Sendable (UUID?, String?) -> Identity,
            preview: @escaping @Sendable (String?) -> String,
            canonicalFrameID: @escaping @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?,
            endedManifests: @escaping @Sendable () throws -> [BrokerSessionManifest],
            searchEndedSession: @escaping @Sendable (
                BrokerSessionManifest,
                String,
                Memory.RetrievalMode,
                Int
            ) async throws -> [EpisodicLaneHit],
            recallEndedSession: @escaping @Sendable (
                BrokerSessionManifest,
                String,
                Memory.RetrievalMode,
                Int,
                FrameFilter?
            ) async throws -> [Hit],
            nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        ) {
            self.longTermMemory = longTermMemory
            self.workingLane = workingLane
            self.inferWriteScope = inferWriteScope
            self.preview = preview
            self.canonicalFrameID = canonicalFrameID
            self.endedManifests = endedManifests
            self.searchEndedSession = searchEndedSession
            self.recallEndedSession = recallEndedSession
            self.nowMs = nowMs
        }
    }

    package struct HorizonLanes: Sendable {
        package var working: [Hit]
        package var episodic: [Hit]
        package var durable: [Hit]
        package var identity: Identity
        package var workingExecution: MemoryOrchestrator.RecallExecution?
        package var durableExecution: MemoryOrchestrator.RecallExecution?
        /// Unscoped durable overfetch for `scope_dropped` only. Not used for kept hits.
        package var dropCandidates: [Hit] = []
    }

    package static func makeMemoryReference(_ id: MemoryID) -> String {
        id.wire
    }

    package static func makeMemoryReference(frameID: UInt64) -> String {
        MemoryID.durable(frameID: frameID).wire
    }

    package static func makeMemoryReference(_ horizon: Horizon, sessionID: UUID, frameID: UInt64) -> String {
        MemoryID.make(horizon: horizon, sessionID: sessionID, frameID: frameID).wire
    }

    package static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package static func resolveIdentity(
        explicitProject: String?,
        explicitRepo: String?,
        sessionProject: String?,
        sessionRepo: String?,
        inferred: Identity
    ) -> Identity {
        var project = normalize(explicitProject)
        var repo = normalize(explicitRepo)
        if project == nil {
            project = normalize(sessionProject)
        }
        if repo == nil {
            repo = normalize(sessionRepo)
        }
        if project == nil {
            project = normalize(inferred.project)
        }
        if repo == nil {
            repo = normalize(inferred.repo)
        }
        return Identity(project: project, repo: repo)
    }

    package static func filterHitsByProject(
        _ hits: [Hit],
        project: String?,
        repo: String?
    ) -> [Hit] {
        hits.filter { hit in
            if let project {
                return hit.metadata[MemoryMetadataKeys.project] == project
            }
            if let repo {
                return hit.metadata[MemoryMetadataKeys.repo] == repo
            }
            return false
        }
    }

    /// Ended virtual session stores eligible for the episodic lane.
    /// Agent filtering applies only when a current session is in scope.
    /// Reclaimed tombstones are excluded; callers still skip missing store files.
    package static func episodicManifests(
        from manifests: [BrokerSessionManifest],
        currentSessionID: UUID?,
        currentAgentID: String?
    ) -> [BrokerSessionManifest] {
        manifests.filter { manifest in
            guard manifest.status == .ended else { return false }
            guard manifest.reclaimedAtMs == nil else { return false }
            if let currentSessionID, manifest.sessionID == currentSessionID { return false }
            if currentSessionID != nil, let currentAgentID, manifest.agentID != currentAgentID {
                return false
            }
            return true
        }
    }

    /// Inflates retrieval top-K when a post-rank project hard-filter may discard foreign hits.
    package static func retrievalTopK(requested: Int, scope: Scope, maxTopK: Int = 200) -> Int {
        let bounded = max(1, requested)
        guard scope != .global else { return bounded }
        return min(max(bounded * 3, bounded), maxTopK)
    }

    /// Merges resolved project/repo identity into the caller's frame filter for retrieval (C1/C3).
    /// Only `scope=project` injects the hard-filter; session/global leave the base filter alone (C7).
    package static func frameFilterForScopedRetrieval(
        base: FrameFilter?,
        scope: Scope,
        identity: Identity
    ) -> FrameFilter? {
        guard scope == .project else { return base }
        guard identity.project != nil || identity.repo != nil else { return base }

        var entries = base?.metadataFilter?.requiredEntries ?? [:]
        if let project = identity.project {
            entries[MemoryMetadataKeys.project] = project
        } else if let repo = identity.repo {
            entries[MemoryMetadataKeys.repo] = repo
        }

        let metadataFilter = MetadataFilter(
            requiredEntries: entries,
            requiredTags: base?.metadataFilter?.requiredTags ?? [],
            requiredLabels: base?.metadataFilter?.requiredLabels ?? []
        )
        return FrameFilter(
            includeDeleted: base?.includeDeleted ?? false,
            includeSuperseded: base?.includeSuperseded ?? false,
            includeSurrogates: base?.includeSurrogates ?? false,
            frameIds: base?.frameIds,
            metadataFilter: metadataFilter
        )
    }

    package static func mergeHits(
        sessionHits: [Hit],
        durableHits: [Hit],
        limit: Int
    ) -> [Hit] {
        func identity(_ hit: Hit) -> String {
            if let hash = hit.metadata["wax.content.hash"] {
                return hash
            }
            return hit.text
        }

        let sessionTagged = sessionHits.map { hit -> Hit in
            var copy = hit
            copy.score += 0.12
            if !copy.explanations.contains("current session") {
                copy.explanations = ["current session"] + copy.explanations
            }
            return copy
        }
        let durableTagged = durableHits.map { hit -> Hit in
            var copy = hit
            if !copy.explanations.contains("durable memory") {
                copy.explanations = ["durable memory"] + copy.explanations
            }
            return copy
        }

        var seen = Set<String>()
        var merged: [Hit] = []
        let ranked = (sessionTagged + durableTagged).sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameID < rhs.frameID
        }
        for hit in ranked {
            guard seen.insert(identity(hit)).inserted else { continue }
            merged.append(hit)
            if merged.count >= limit { break }
        }

        func ensureHorizon(from hits: [Hit], marker: String) {
            guard !hits.isEmpty else { return }
            guard !merged.contains(where: { $0.explanations.contains(marker) }) else { return }
            guard let extra = hits
                .filter({ !seen.contains(identity($0)) })
                .max(by: { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score < rhs.score }
                    return lhs.frameID > rhs.frameID
                })
            else { return }

            if merged.count >= limit {
                guard let evictIndex = merged.lastIndex(where: { !$0.explanations.contains(marker) }) else {
                    return
                }
                let evicted = merged.remove(at: evictIndex)
                seen.remove(identity(evicted))
            }
            seen.insert(identity(extra))
            merged.append(extra)
        }
        ensureHorizon(from: sessionTagged, marker: "current session")
        ensureHorizon(from: durableTagged, marker: "durable memory")
        if merged.count > limit {
            merged = Array(merged.prefix(limit))
        }
        merged.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameID < rhs.frameID
        }
        return merged
    }

    /// Scope selection after merge (project hard-filter + miss messaging).
    /// `scope=session` and `scope=global` skip project hard-filter (C7).
    package static func selectHits(
        merged: [Hit],
        scope: Scope,
        identity: Identity
    ) -> (hits: [Hit], projectMiss: Bool, scopeMissMessage: String?, scopeDropped: ScopeDropped) {
        if scope == .global || scope == .session {
            return (merged, false, nil, .empty)
        }
        // scope == .project
        let filtered = filterHitsByProject(merged, project: identity.project, repo: identity.repo)
        if identity.project == nil && identity.repo == nil {
            return (
                [],
                true,
                "no frames for project (unresolved); pass project/repo or scope=global",
                .empty
            )
        }
        if filtered.isEmpty {
            let label = identity.project.map { "project \($0)" }
                ?? identity.repo.map { "repo \($0)" }
                ?? "project"
            return ([], true, "no frames for \(label)", .empty)
        }
        return (filtered, false, nil, louderDropped(merged: merged, kept: filtered, identity: identity))
    }

    /// Foreign hits scoring ≥ the kept top. Empty-lane miss stays `projectMiss`; never auto-widens.
    private static func louderDropped(
        merged: [Hit],
        kept: [Hit],
        identity: Identity
    ) -> ScopeDropped {
        guard let maxKept = kept.map(\.score).max() else { return .empty }
        let foreign = merged.filter { hit in
            filterHitsByProject([hit], project: identity.project, repo: identity.repo).isEmpty
        }
        let louder = foreign.filter { $0.score >= maxKept }
        guard !louder.isEmpty else { return .empty }
        let ranked = louder.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameID < rhs.frameID
        }
        let top = ranked.prefix(3).map { hit in
            ScopeDropped.Entry(
                project: hit.metadata[MemoryMetadataKeys.project],
                repo: hit.metadata[MemoryMetadataKeys.repo],
                score: hit.score,
                preview: hit.preview
            )
        }
        return ScopeDropped(
            count: louder.count,
            top: Array(top),
            hint: "pass scope=global for cross-project — do not auto-widen"
        )
    }

    package static func hit(from item: RAGContext.Item, horizon: Horizon, sessionID: UUID) -> Hit {
        hit(from: item, id: MemoryID.make(horizon: horizon, sessionID: sessionID, frameID: item.frameId))
    }

    package static func hit(from item: RAGContext.Item) -> Hit {
        hit(from: item, id: .durable(frameID: item.frameId))
    }

    package static func hit(from item: RAGContext.Item, id: MemoryID) -> Hit {
        Hit(
            id: id,
            score: item.score,
            text: item.text,
            preview: MemorySemantics.summarizeCandidate(item.text, maxLength: 180),
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
        limit: Int
    ) -> [RAGContext.Item] {
        let sessionHits = sessionItems.map {
            hit(from: $0, horizon: .working, sessionID: UUID())
        }
        let durableHits = durableItems.map { hit(from: $0) }
        return mergeHits(sessionHits: sessionHits, durableHits: durableHits, limit: limit).map { hit in
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
        let rankingScope = MemoryScopeContext(
            repoName: identity.repo,
            projectName: identity.project
        )
        // Primary working/durable retrieval stays project-scoped so foreign hits
        // cannot crowd out the lane. Unscoped durable overfetch is dropCandidates
        // only. Episodic keeps the scoped helper.
        let scopedFrameFilter = Self.frameFilterForScopedRetrieval(
            base: request.frameFilter,
            scope: request.scope,
            identity: identity
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
            if sessionHits.isEmpty {
                let documents = try await working.memory.corpusSourceDocuments()
                    .sorted { lhs, rhs in
                        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
                        return lhs.frameId > rhs.frameId
                    }
                sessionHits = documents.prefix(topK).map { document in
                    Hit(
                        id: .working(sessionID: working.sessionID, frameID: document.frameId),
                        agentID: working.agentID,
                        runID: working.runID,
                        score: 0.2,
                        text: document.text,
                        preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                        metadata: document.metadata,
                        explanations: ["current session", "recent session note"],
                        timestampMs: document.timestampMs,
                        kind: .snippet,
                        sources: [.text]
                    )
                }
            } else {
                sessionHits = sessionHits.map { hit in
                    var copy = hit
                    copy.agentID = working.agentID
                    copy.runID = working.runID
                    copy.timestampMs = working.updatedAtMs
                    return copy
                }
            }
            if canonicalizeFrameIDs {
                sessionHits = await canonicalizeHits(sessionHits, memory: working.memory, stores: stores)
            }
        }

        var durableHits: [Hit] = []
        var durableExecution: MemoryOrchestrator.RecallExecution?
        var dropCandidates: [Hit] = []
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
            if request.scope == .project {
                let dropExecution = try await stores.longTermMemory.recallExecution(
                    query: request.query,
                    mode: request.mode,
                    frameFilter: request.frameFilter,
                    timeRange: request.timeRange,
                    topK: topK,
                    scopeContext: rankingScope
                )
                dropCandidates = visibleDurableHits(
                    from: dropExecution,
                    request: request,
                    nowMs: stores.nowMs()
                )
            }
        }

        var episodicHits: [Hit] = []
        if horizons.contains(.episodic) {
            let selected = onDiskEpisodicManifests(
                episodicManifests(
                    from: try stores.endedManifests(),
                    currentSessionID: request.sessionID,
                    currentAgentID: working?.agentID
                )
            )
            for manifest in selected {
                let hits = try await stores.recallEndedSession(
                    manifest,
                    request.query,
                    request.mode ?? .hybrid(),
                    max(1, episodicTopK),
                    scopedFrameFilter
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
            durableExecution: durableExecution,
            dropCandidates: dropCandidates
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

    package static func recall(
        request: RecallRequest,
        stores: Stores
    ) async throws -> RecallResult {
        var fetchRequest = request
        fetchRequest.searchTopK = retrievalTopK(requested: request.searchTopK, scope: request.scope)
        let lanes = try await fetchLanes(request: fetchRequest, stores: stores)
        let identity = lanes.identity

        let merged: [Hit]
        if request.scope == .session {
            merged = Array(lanes.working.prefix(request.limit))
        } else if request.scope == .project {
            // Filter before merge so foreign ranks cannot consume the result budget.
            let scopedSession = Self.filterHitsByProject(
                lanes.working,
                project: identity.project,
                repo: identity.repo
            )
            let scopedDurable = Self.filterHitsByProject(
                lanes.durable,
                project: identity.project,
                repo: identity.repo
            )
            merged = mergeHits(
                sessionHits: scopedSession,
                durableHits: scopedDurable,
                limit: request.limit
            )
        } else {
            merged = mergeHits(
                sessionHits: lanes.working,
                durableHits: lanes.durable,
                limit: request.limit
            )
        }

        let selected = selectHits(merged: merged, scope: request.scope, identity: identity)
        let keptHits = Array(selected.hits.prefix(request.limit))
        let scopeDropped: ScopeDropped
        if request.scope == .project {
            scopeDropped = louderDropped(
                merged: lanes.dropCandidates,
                kept: keptHits,
                identity: identity
            )
        } else {
            scopeDropped = selected.scopeDropped
        }
        let primary = lanes.workingExecution ?? lanes.durableExecution

        return RecallResult(
            hits: keptHits,
            scope: request.scope,
            identity: identity,
            projectMiss: selected.projectMiss,
            scopeMissMessage: selected.scopeMissMessage,
            scopeDropped: scopeDropped,
            requestedModeSummary: primary?.requestedMode.diagnosticsSummary ?? "n/a",
            effectiveModeSummary: primary?.effectiveMode.diagnosticsSummary ?? "n/a",
            queryEmbeddingState: primary?.queryEmbeddingState.rawValue ?? "n/a",
            searchTopK: request.searchTopK,
            limit: request.limit
        )
    }

    package static func search(
        request: SearchRequest,
        stores: Stores
    ) async throws -> [Hit] {
        var hits: [Hit] = []

        if request.horizons.contains(.working), let sessionID = request.sessionID, let lane = stores.workingLane(sessionID) {
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
                        timestampMs: lane.updatedAtMs,
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
            let scopedManifests = onDiskEpisodicManifests(
                episodicManifests(
                    from: try stores.endedManifests(),
                    currentSessionID: request.sessionID,
                    currentAgentID: currentAgentID
                )
            )
            .prefix(6)

            for manifest in scopedManifests {
                let laneHits = try await stores.searchEndedSession(
                    manifest,
                    request.query,
                    request.mode,
                    max(1, min(3, request.topK))
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
                            timestampMs: manifest.updatedAtMs,
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

    private static func onDiskEpisodicManifests(
        _ manifests: [BrokerSessionManifest]
    ) -> [BrokerSessionManifest] {
        manifests.filter { FileManager.default.fileExists(atPath: $0.storePath) }
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
