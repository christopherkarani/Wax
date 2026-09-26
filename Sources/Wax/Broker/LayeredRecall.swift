import Foundation
import WaxCore

/// Closed recall scope together with the working-lane session id after wire decode.
///
/// `.session` requires a UUID. `.project` and `.global` keep an optional working
/// session so MCP can still consult that lane.
package enum RecallIdentity: Sendable, Equatable {
    case project(workingSessionID: UUID?)
    case session(workingSessionID: UUID)
    case global(workingSessionID: UUID?)

    package var scope: LayeredRecall.Scope {
        switch self {
        case .project: return .project
        case .session: return .session
        case .global: return .global
        }
    }

    package var sessionID: UUID? {
        switch self {
        case .project(let sessionID), .global(let sessionID):
            return sessionID
        case .session(let sessionID):
            return sessionID
        }
    }

    package static func make(
        scope: LayeredRecall.Scope,
        sessionID: UUID?
    ) throws -> RecallIdentity {
        switch scope {
        case .project:
            return .project(workingSessionID: sessionID)
        case .session:
            guard let sessionID else {
                throw BrokerValidationError.invalid("scope session requires session_id")
            }
            return .session(workingSessionID: sessionID)
        case .global:
            return .global(workingSessionID: sessionID)
        }
    }
}

/// Post-resolution layered search identity.
///
/// Working requires a session UUID. Unscoped working and empty horizons are not
/// cases — they fail at ``make(sessionID:horizons:)`` / ``unscoped(_:)`` /
/// ``session(sessionID:horizons:)``.
package struct MemorySearchIdentity: Sendable, Equatable {
    private enum Kind: Sendable, Equatable {
        case unscoped(HorizonSet)
        case session(sessionID: UUID, horizons: HorizonSet)
    }

    private let kind: Kind

    package var sessionID: UUID? {
        switch kind {
        case .unscoped:
            return nil
        case .session(let sessionID, _):
            return sessionID
        }
    }

    package var horizons: HorizonSet {
        switch kind {
        case .unscoped(let horizons), .session(_, let horizons):
            return horizons
        }
    }

    /// Non-nil only when a session identity includes `.working`.
    package var workingSessionID: UUID? {
        switch kind {
        case .session(let sessionID, let horizons):
            return horizons.contains(.working) ? sessionID : nil
        case .unscoped:
            return nil
        }
    }

    /// True only on session identity when horizons contain `.working`.
    package var includesWorking: Bool { workingSessionID != nil }

    package static func unscoped(_ horizons: HorizonSet) throws -> MemorySearchIdentity {
        try make(sessionID: nil, horizons: horizons)
    }

    package static func session(
        sessionID: UUID,
        horizons: HorizonSet
    ) throws -> MemorySearchIdentity {
        try make(sessionID: sessionID, horizons: horizons)
    }

    package static func make(
        sessionID: UUID?,
        horizons: HorizonSet
    ) throws -> MemorySearchIdentity {
        guard !horizons.isEmpty else {
            throw BrokerValidationError.invalid(
                "memory search identity requires a non-empty horizon set"
            )
        }
        if let sessionID {
            return MemorySearchIdentity(kind: .session(sessionID: sessionID, horizons: horizons))
        }
        if horizons.contains(.working) {
            throw BrokerValidationError.invalid("working horizon requires a session_id")
        }
        return MemorySearchIdentity(kind: .unscoped(horizons))
    }
}

/// Non-lane retrieval control bits. Ranking reasons stay open explanation strings.
package struct HitFlags: OptionSet, Sendable, Hashable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let ownerCard = HitFlags(rawValue: 1 << 0)
    package static let unlandedDemoted = HitFlags(rawValue: 1 << 1)
}

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
        package var conversationID: String?
        package var score: Float
        package var text: String
        package var preview: String
        package var metadata: [String: String]
        package var explanations: [String]
        package var timestampMs: Int64
        package var kind: RAGContext.ItemKind
        package var sources: [RAGContext.Source]
        package var collapsedCount: Int
        package var flags: HitFlags

        package var reference: String { id.wire }
        package var horizon: Horizon { id.horizon }
        package var sessionID: UUID? { id.sessionID }
        package var frameID: UInt64 { id.frameID }

        package init(
            id: MemoryID,
            agentID: String? = nil,
            runID: String? = nil,
            conversationID: String? = nil,
            score: Float,
            text: String,
            preview: String,
            metadata: [String: String],
            explanations: [String],
            timestampMs: Int64,
            kind: RAGContext.ItemKind = .snippet,
            sources: [RAGContext.Source] = [],
            collapsedCount: Int = 1,
            flags: HitFlags = []
        ) {
            self.id = id
            self.agentID = agentID
            self.runID = runID
            self.conversationID = conversationID
            self.score = score
            self.text = text
            self.preview = preview
            self.metadata = metadata
            self.explanations = explanations
            self.timestampMs = timestampMs
            self.kind = kind
            self.sources = sources
            self.collapsedCount = max(1, collapsedCount)
            self.flags = flags
        }
    }

    package typealias MemoryReference = MemoryID

    package struct WorkingLane: Sendable {
        package var sessionID: UUID
        package var agentID: String?
        package var runID: String?
        package var conversationID: String?
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
            memory: MemoryOrchestrator,
            conversationID: String? = nil
        ) {
            self.sessionID = sessionID
            self.agentID = agentID
            self.runID = runID
            self.conversationID = conversationID
            self.updatedAtMs = updatedAtMs
            self.project = project
            self.repo = repo
            self.memory = memory
        }
    }

    /// Coerced tool args; Layered recall owns what the fields mean.
    package struct RecallRequest: Sendable {
        package var query: String
        package var identity: RecallIdentity
        package var limit: Int
        package var searchTopK: Int
        package var mode: Memory.RetrievalMode?
        package var explicitProject: String?
        package var explicitRepo: String?
        package var clientCWD: String?
        package var frameFilter: FrameFilter?
        package var timeRange: SearchTimeRange?
        package var memoryTypes: [MemoryType]
        package var includeWorking: Bool

        package var scope: Scope { identity.scope }
        package var sessionID: UUID? { identity.sessionID }

        /// Working lane is conversation-scoped: it enters recall only through
        /// an explicit session scope or an explicit `include_working` opt-in.
        /// A merely present session id (project/global identity, MCP injection)
        /// never implies it.
        package var includesWorkingLane: Bool {
            scope == .session || includeWorking
        }

        /// Recall fetches working + durable; episodic stays a memory_search /
        /// compact lane. Gated requests fetch durable only.
        package var fetchHorizons: HorizonSet {
            includesWorkingLane ? [.working, .durable] : [.durable]
        }

        package init(
            query: String,
            identity: RecallIdentity,
            limit: Int,
            searchTopK: Int,
            mode: Memory.RetrievalMode? = nil,
            explicitProject: String? = nil,
            explicitRepo: String? = nil,
            clientCWD: String? = nil,
            frameFilter: FrameFilter? = nil,
            timeRange: SearchTimeRange? = nil,
            memoryTypes: [MemoryType] = [],
            includeWorking: Bool = false
        ) {
            self.query = query
            self.identity = identity
            self.limit = limit
            self.searchTopK = searchTopK
            self.mode = mode
            self.explicitProject = explicitProject
            self.explicitRepo = explicitRepo
            self.clientCWD = clientCWD
            self.frameFilter = frameFilter
            self.timeRange = timeRange
            self.memoryTypes = memoryTypes
            self.includeWorking = includeWorking
        }
    }

    package struct SearchRequest: Sendable {
        package var query: String
        package var mode: Memory.RetrievalMode
        package var topK: Int
        package var identity: MemorySearchIdentity

        package var sessionID: UUID? { identity.sessionID }
        package var horizons: HorizonSet { identity.horizons }

        package init(
            query: String,
            mode: Memory.RetrievalMode,
            topK: Int,
            identity: MemorySearchIdentity
        ) {
            self.query = query
            self.mode = mode
            self.topK = topK
            self.identity = identity
        }

        package init(
            query: String,
            mode: Memory.RetrievalMode,
            topK: Int,
            sessionID: UUID? = nil,
            horizons: HorizonSet
        ) throws {
            try self.init(
                query: query,
                mode: mode,
                topK: topK,
                identity: MemorySearchIdentity.make(sessionID: sessionID, horizons: horizons)
            )
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

    /// Broker-only retrieval outcome across working/durable lanes.
    /// `"mixed"` / `"n/a"` are wire strings here — they are not
    /// ``RAGContext/QueryEmbeddingState`` cases.
    package enum LaneDiagnostics: Sendable, Equatable {
        case unavailable
        case uniform(RAGContext.Diagnostics)
        case mixed(requested: SearchMode)

        package var wireRequestedMode: String {
            switch self {
            case .unavailable:
                return "n/a"
            case .uniform(let diagnostics):
                return diagnostics.requestedMode.diagnosticsSummary
            case .mixed(let requested):
                return requested.diagnosticsSummary
            }
        }

        package var wireEffectiveMode: String {
            switch self {
            case .unavailable:
                return "n/a"
            case .uniform(let diagnostics):
                return diagnostics.effectiveMode.diagnosticsSummary
            case .mixed:
                return "mixed"
            }
        }

        package var wireQueryEmbeddingState: String {
            switch self {
            case .unavailable:
                return "n/a"
            case .uniform(let diagnostics):
                return diagnostics.queryEmbeddingState.rawValue
            case .mixed:
                return "mixed"
            }
        }
    }

    package struct RecallResult: Sendable {
        package var hits: [Hit]
        package var scope: Scope
        package var identity: Identity
        package var projectMiss: Bool
        package var scopeMissMessage: String?
        package var scopeDropped: ScopeDropped = .empty
        package var diagnostics: LaneDiagnostics
        package var searchTopK: Int
        package var retrievalTopK: Int
        package var limit: Int
        package var collapsed: Int = 0

        package var requestedModeSummary: String { diagnostics.wireRequestedMode }
        package var effectiveModeSummary: String { diagnostics.wireEffectiveMode }
        package var queryEmbeddingState: String { diagnostics.wireQueryEmbeddingState }
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
        package var endedSessions: any EndedSessionStore
        package var nowMs: @Sendable () -> Int64

        package init(
            longTermMemory: MemoryOrchestrator,
            workingLane: @escaping @Sendable (UUID) -> WorkingLane?,
            inferWriteScope: @escaping @Sendable (UUID?, String?) -> Identity,
            preview: @escaping @Sendable (String?) -> String,
            canonicalFrameID: @escaping @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?,
            endedSessions: any EndedSessionStore,
            nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        ) {
            self.longTermMemory = longTermMemory
            self.workingLane = workingLane
            self.inferWriteScope = inferWriteScope
            self.preview = preview
            self.canonicalFrameID = canonicalFrameID
            self.endedSessions = endedSessions
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
        let explicitProject = normalize(explicitProject)
        let explicitRepo = normalize(explicitRepo)
        if explicitProject != nil || explicitRepo != nil {
            return Identity(project: explicitProject, repo: explicitRepo)
        }
        var project: String?
        var repo: String?
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
        let identity = Identity(project: normalize(project), repo: normalize(repo))
        return hits.filter { matchesProjectScope($0, identity: identity) }
    }

    package static func filterHitsByMemoryTypes(_ hits: [Hit], types: [MemoryType]) -> [Hit] {
        guard !types.isEmpty else { return hits }
        let wanted = Set(types.map(\.rawValue))
        return hits.filter { hit in
            guard let raw = hit.metadata[MemoryMetadataKeys.type] else { return false }
            return wanted.contains(raw)
        }
    }

    /// Project recall keeps only own-conversation task_state. task_state is
    /// conversation-scoped working memory; a durable hit stamped with another
    /// session's provenance is another conversation's diary, not project
    /// knowledge. Only positively-foreign stamps drop — unstamped hits stay,
    /// like the other unstamped-stays filters, and non-task_state is untouched.
    /// Project recall keeps only own-conversation task_state. task_state is
    /// conversation-scoped working memory; a hit stamped with another
    /// session's provenance is another conversation's diary, not project
    /// knowledge. Only positively-foreign stamps drop — unstamped hits stay,
    /// like the other unstamped-stays filters, and non-task_state is untouched.
    package static func filterForeignTaskState(_ hits: [Hit], sessionID: UUID?) -> [Hit] {
        hits.filter { hit in
            guard hit.metadata[MemoryMetadataKeys.type] == MemoryType.taskState.rawValue else {
                return true
            }
            guard let raw = taskStateSessionStamp(hit.metadata) else {
                return true
            }
            guard let stamped = UUID(uuidString: raw) else {
                return false
            }
            return stamped == sessionID
        }
    }

    /// Session stamp behind a task_state hit, mirroring the task_state
    /// migration's provenance lookup plus its repaired-store key.
    package static func taskStateSessionStamp(_ metadata: [String: String]) -> String? {
        metadata["session_id"]
            ?? metadata[MemoryMetadataKeys.promotedFromSession]
            ?? metadata[MemoryMetadataKeys.migrationOriginalSessionID]
    }

    /// Person-lane (`user_preference` only) drops other-project/other-repo prefs
    /// when identity is resolved. Unscoped prefs stay. Unresolved identity is a no-op.
    package static func filterHitsForGlobalPersonLane(
        _ hits: [Hit],
        memoryTypes: [MemoryType],
        identity: Identity
    ) -> [Hit] {
        guard memoryTypes == [.userPreference],
              identity.project != nil || identity.repo != nil
        else {
            return hits
        }
        return filterHitsByProject(hits, project: identity.project, repo: identity.repo)
    }

    /// Unresolved project keeps the live working lane and unstamped durable/episodic
    /// hits. Stamped foreign durable is dropped so we never auto-widen. Resolved
    /// identity keeps unstamped hits (they are not a different project).
    package static func matchesProjectScope(_ hit: Hit, identity: Identity) -> Bool {
        if identity.project == nil && identity.repo == nil {
            if hit.horizon == .working { return true }
            return !hasExplicitProjectOrRepo(hit)
        }
        return matchesIdentityOrUnscoped(hit, identity: identity)
    }

    package static func hasExplicitProjectOrRepo(_ hit: Hit) -> Bool {
        let project = hit.metadata[MemoryMetadataKeys.project]
        let repo = hit.metadata[MemoryMetadataKeys.repo]
        return (project.map { !$0.isEmpty } ?? false) || (repo.map { !$0.isEmpty } ?? false)
    }

    package static func matchesIdentityOrUnscoped(_ hit: Hit, identity: Identity) -> Bool {
        let projectMatches = identity.project.map { wanted in
            let actual = hit.metadata[MemoryMetadataKeys.project]
            if actual == nil || actual == "" { return true }
            return actual == wanted
        } ?? true
        let repoMatches = identity.repo.map { wanted in
            let actual = hit.metadata[MemoryMetadataKeys.repo]
            if actual == nil || actual == "" { return true }
            return actual == wanted
        } ?? true
        return projectMatches && repoMatches
    }

    /// Ended virtual session stores eligible for the episodic lane.
    /// Agent filtering applies only when a current session is in scope.
    /// Reclaimed tombstones are excluded. Missing store files are skipped by the
    /// ended-session adapter, not here.
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
    package static func retrievalTopK(requested: Int, maxTopK: Int = 200) -> Int {
        let bounded = max(1, requested)
        return min(max(bounded * 3, 12), maxTopK)
    }

    /// Person-lane post-filters other-project prefs after a type-only retrieval.
    /// Over-fetch further so current-project and unscoped prefs still make the window.
    package static func retrievalTopKForGlobalPersonLane(requested: Int, maxTopK: Int = 200) -> Int {
        let bounded = max(1, requested)
        return min(max(bounded * 8, 48), maxTopK)
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
        }
        if let repo = identity.repo {
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

    /// Single-type `memory_types` is a retrieval hard-filter. Multiple types stay
    /// post-filter because metadata entries are exact AND matches, not OR.
    package static func frameFilterForMemoryTypes(
        base: FrameFilter?,
        types: [MemoryType]
    ) -> FrameFilter? {
        let unique = Set(types)
        guard unique.count == 1, let type = unique.first else { return base }
        var entries = base?.metadataFilter?.requiredEntries ?? [:]
        entries[MemoryMetadataKeys.type] = type.rawValue
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

    package static let recallClusterJaccardThreshold: Float = 0.55
    package static let scorecardRankPenalty: Float = 0.40
    package static let unlandedSkipListPenalty: Float = 0.40

    package static func collapsedTotal(in hits: [Hit]) -> Int {
        hits.reduce(0) { $0 + max(0, $1.collapsedCount - 1) }
    }

    package static func mergeHits(
        sessionHits: [Hit],
        durableHits: [Hit],
        limit: Int,
        nowMs: Int64,
        query: String? = nil,
        liveCheckout: GitCheckoutSnapshot? = nil,
        relations: [String: OnThisTree] = [:]
    ) -> [Hit] {
        func identity(_ hit: Hit) -> String {
            // Locked frames stay live even against an identical unlocked twin.
            if isLockedHit(hit) {
                return "locked:" + hit.reference
            }
            if let hash = hit.metadata["wax.content.hash"] {
                return hash
            }
            return hit.text
        }

        func checkoutRelation(storedSHA: String?) -> OnThisTree? {
            if let storedSHA, let mapped = relations[storedSHA] {
                return mapped
            }
            guard let liveCheckout else { return nil }
            return MemorySemantics.classifyCheckout(storedSHA: storedSHA, live: liveCheckout)
        }

        func adjustFreshness(_ hit: Hit) -> Hit {
            var copy = hit
            if let relation = checkoutRelation(storedSHA: hit.metadata[MemoryMetadataKeys.gitSHA]) {
                copy.metadata[MemoryMetadataKeys.onThisTree] = relation.rawValue
            }
            let adjusted = rankingAdjustedScore(
                copy,
                nowMs: nowMs,
                query: query,
                liveCheckout: liveCheckout
            )
            if adjusted != hit.score {
                copy.score = adjusted
                if freshnessAdjustedScore(hit, nowMs: nowMs) != hit.score {
                    copy.explanations.append("freshness adjusted operational memory")
                }
                if adjusted != freshnessAdjustedScore(hit, nowMs: nowMs) {
                    copy.explanations.append("query-aware recency ranking")
                }
            }
            return copy
        }

        let sessionTagged = sessionHits.map { hit -> Hit in
            var copy = hit
            // Lexical session notes should surface immediately. Vector-only
            // working neighbors already have a similarity score; a flat boost
            // lets unrelated task_state beat the durable fact MiniLM ranked first.
            if hit.sources.contains(.text) || hit.sources.isEmpty {
                copy.score += 0.12
            }
            if !copy.explanations.contains("current session") {
                copy.explanations = ["current session"] + copy.explanations
            }
            return adjustFreshness(copy)
        }
        let durableTagged = durableHits.map { hit -> Hit in
            var copy = hit
            if !copy.explanations.contains("durable memory") {
                copy.explanations = ["durable memory"] + copy.explanations
            }
            return adjustFreshness(copy)
        }

        let queryAsks = queryAsksForRating(query)
        let tagged = sessionTagged + durableTagged
        let unlandedIDs = unlandedClaimIdentifiers(in: tagged)
        let candidates = tagged.map { demoteUnlandedSkipList($0, unlandedIDs: unlandedIDs) }
        let ranked = candidates.sorted(by: higherRank)
        let clustered = clusterHits(ranked, identity: identity)
        var seen = Set<String>()
        var merged: [Hit] = []
        // Default queries drop scorecards (oracle: absent unless asked). −0.40
        // still applies in rankingAdjustedScore so a leaked card ranks below work.
        for hit in clustered.sorted(by: higherRank) {
            if looksScorecard(hit.text), !queryAsks { continue }
            guard seen.insert(identity(hit)).inserted else { continue }
            merged.append(hit)
            if merged.count >= limit { break }
        }

        func shouldSkipReservation(_ extra: Hit) -> Bool {
            if looksScorecard(extra.text), !queryAsks { return true }
            if extra.flags.contains(.unlandedDemoted) { return true }
            if merged.contains(where: { sameCluster($0, extra) || isParaphrase($0, extra) }) {
                return true
            }
            return false
        }

        func ensureHorizon(from hits: [Hit], horizon: Horizon) {
            guard !hits.isEmpty else { return }
            guard !merged.contains(where: { $0.horizon == horizon }) else { return }
            guard let extra = hits
                .filter({ !seen.contains(identity($0)) && !shouldSkipReservation($0) })
                .max(by: { higherRank($1, $0) })
            else { return }

            if merged.count >= limit {
                guard let evictIndex = merged.lastIndex(where: { $0.horizon != horizon }) else {
                    return
                }
                let evicted = merged.remove(at: evictIndex)
                seen.remove(identity(evicted))
            }
            seen.insert(identity(extra))
            merged.append(extra)
        }
        ensureHorizon(
            from: clustered.filter { $0.horizon == .working },
            horizon: .working
        )
        ensureHorizon(
            from: clustered.filter { $0.horizon == .durable },
            horizon: .durable
        )
        if merged.count > limit {
            merged = Array(merged.prefix(limit))
        }
        merged.sort(by: higherRank)
        return merged
    }

    package static func looksScorecard(_ text: String) -> Bool {
        if isStaleIgnoreList(text) { return false }
        let lowered = text.lowercased()
        let ratingDump = lowered.range(of: #"\b\d{1,3}\s*/\s*100\b"#, options: .regularExpression) != nil
        let sessionRubric = lowered.contains("for this session")
            && lowered.contains("would use it again")
        return ratingDump || sessionRubric
    }

    package static func queryAsksForRating(_ query: String?) -> Bool {
        let lowered = query?.lowercased() ?? ""
        guard !lowered.isEmpty else { return false }
        return lowered.contains("rating") || lowered.contains("score")
    }

    private static func clusterHits(
        _ hits: [Hit],
        identity: (Hit) -> String
    ) -> [Hit] {
        var identityCounts: [String: Int] = [:]
        identityCounts.reserveCapacity(hits.count)
        for hit in hits {
            identityCounts[identity(hit), default: 0] += 1
        }

        var unique: [Hit] = []
        unique.reserveCapacity(hits.count)
        var seen = Set<String>()
        for hit in hits {
            guard seen.insert(identity(hit)).inserted else { continue }
            unique.append(hit)
        }

        var clusters: [[Hit]] = []
        for hit in unique {
            if let index = clusters.firstIndex(where: { group in
                group.contains { sameCluster($0, hit) }
            }) {
                clusters[index].append(hit)
            } else {
                clusters.append([hit])
            }
        }

        return clusters.map { group in
            var winner = pickClusterWinner(group)
            let count = group.reduce(0) { $0 + max(1, identityCounts[identity($1)] ?? 1) }
            winner.collapsedCount = max(1, count)
            return winner
        }
    }

    private static func isLockedHit(_ hit: Hit) -> Bool {
        hit.metadata[MemoryMetadataKeys.durability] == MemoryDurability.locked.rawValue
    }

    private static func sameCluster(_ lhs: Hit, _ rhs: Hit) -> Bool {
        if lhs.id == rhs.id { return true }
        // Locked frames stay live; never fold them into another row.
        if isLockedHit(lhs) || isLockedHit(rhs) { return false }
        if isExactDuplicate(lhs, rhs) { return true }
        // Paraphrases collapse only inside one horizon. A durable fact must not
        // eat a current-session mention that shares a token.
        if lhs.horizon != rhs.horizon { return false }
        return isParaphrase(lhs, rhs)
    }

    private static func isExactDuplicate(_ lhs: Hit, _ rhs: Hit) -> Bool {
        if lhs.text == rhs.text { return true }
        if let leftHash = lhs.metadata["wax.content.hash"],
           let rightHash = rhs.metadata["wax.content.hash"],
           leftHash == rightHash {
            return true
        }
        return false
    }

    private static func isParaphrase(_ lhs: Hit, _ rhs: Hit) -> Bool {
        let leftProject = lhs.metadata[MemoryMetadataKeys.project].flatMap { $0.isEmpty ? nil : $0 }
        let rightProject = rhs.metadata[MemoryMetadataKeys.project].flatMap { $0.isEmpty ? nil : $0 }
        if leftProject != rightProject {
            return false
        }
        let leftCard = looksScorecard(lhs.text)
        let rightCard = looksScorecard(rhs.text)
        if leftCard != rightCard { return false }
        if MemorySemantics.identifiersMatch(lhs.text, rhs.text) { return true }
        return MemorySemantics.similarity(lhs: lhs.text, rhs: rhs.text) >= recallClusterJaccardThreshold
    }

    private static func pickClusterWinner(_ group: [Hit]) -> Hit {
        group.max { lhs, rhs in
            let leftTier = standingClusterTier(lhs)
            let rightTier = standingClusterTier(rhs)
            if leftTier != rightTier { return leftTier < rightTier }
            let leftOpen = looksSkipThisSession(lhs.text) ? 0 : 1
            let rightOpen = looksSkipThisSession(rhs.text) ? 0 : 1
            if leftOpen != rightOpen { return leftOpen < rightOpen }
            if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs < rhs.timestampMs }
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.frameID < rhs.frameID
        } ?? group[0]
    }

    package static func looksSkipThisSession(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let skipRun = lowered.contains("do not re-run")
            || lowered.contains("don't re-run")
            || lowered.contains("do not rerun")
        return skipRun && lowered.contains("this session")
    }

    package static func looksSkipList(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("do not re-run")
            || lowered.contains("don't re-run")
            || lowered.contains("do not rerun") {
            return true
        }
        return lowered.contains("do not re-propose") || lowered.contains("don't re-propose")
    }

    private static func unlandedClaimIdentifiers(in hits: [Hit]) -> Set<String> {
        var ids = Set<String>()
        for hit in hits {
            guard isUnlandedClaim(hit) else { continue }
            ids.formUnion(MemorySemantics.extractIdentifiers(hit.text))
        }
        return ids
    }

    private static func isUnlandedClaim(_ hit: Hit) -> Bool {
        // Skip-list rows must not seed their own demotion. Ancestor counts:
        // intent on a parent SHA is still not shipped on this tree (W5 child
        // dropped GitLiveProbe.md while skip-list said do-not-re-run C01).
        guard !looksSkipList(hit.text) else { return false }
        let tree = OnThisTree(rawValue: hit.metadata[MemoryMetadataKeys.onThisTree] ?? "")
        guard tree == .other || tree == .ancestor || tree == .unknown else {
            return false
        }
        return MemorySemantics.looksLandedClaim(metadata: hit.metadata, text: hit.text)
    }

    private static func demoteUnlandedSkipList(_ hit: Hit, unlandedIDs: Set<String>) -> Hit {
        guard looksSkipList(hit.text), !unlandedIDs.isEmpty else { return hit }
        let ids = MemorySemantics.extractIdentifiers(hit.text)
        let shared = ids.intersection(unlandedIDs)
        let mostlyUnlanded = !ids.isEmpty && (Float(shared.count) / Float(ids.count) >= 0.5)
        guard shared.count >= 2 || mostlyUnlanded else { return hit }
        var copy = hit
        copy.score -= unlandedSkipListPenalty
        copy.flags.insert(.unlandedDemoted)
        if !copy.explanations.contains("unlanded skip-list demoted") {
            copy.explanations.append("unlanded skip-list demoted")
        }
        return copy
    }

    private static func standingClusterTier(_ hit: Hit) -> Int {
        switch MemoryType(rawValue: hit.metadata[MemoryMetadataKeys.type] ?? "") {
        case .constraint, .decision, .lesson, .fact, .userPreference:
            return 1
        case .note, .taskState, .handoff, nil:
            return 0
        }
    }

    private static func higherRank(_ lhs: Hit, _ rhs: Hit) -> Bool {
        let leftDemoted = lhs.flags.contains(.unlandedDemoted)
        let rightDemoted = rhs.flags.contains(.unlandedDemoted)
        if leftDemoted != rightDemoted { return !leftDemoted }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
        return lhs.frameID > rhs.frameID
    }

    /// Recency only nudges short-lived operational memory. Durable preferences,
    /// facts, lessons, decisions, constraints, reviewed frames, and locked frames
    /// keep their semantic score regardless of age.
    package static func freshnessAdjustedScore(_ hit: Hit, nowMs: Int64) -> Float {
        let isOperational = switch MemoryType(rawValue: hit.metadata[MemoryMetadataKeys.type] ?? "") {
        case .note, .taskState, .handoff: true
        case .userPreference, .decision, .lesson, .constraint, .fact, nil: false
        }
        let isReviewed = hit.metadata[MemoryMetadataKeys.reviewed]?.lowercased() == "true"
        let isLocked = hit.metadata[MemoryMetadataKeys.durability] == MemoryDurability.locked.rawValue
        guard isOperational, !isReviewed, !isLocked, hit.timestampMs > 0, nowMs > hit.timestampMs else {
            return hit.score
        }
        let ageDays = Float(nowMs - hit.timestampMs) / 86_400_000
        let penalty = min(0.18, max(0, ageDays / 30) * 0.18)
        return hit.score - penalty
    }

    /// Query-aware ranking on top of operational freshness.
    ///
    /// Locked "do not follow / stale frames" lists stay out of today's work
    /// queries. Unlocked standing corrections that happen to use those phrases
    /// keep their semantic score. Fresh standing facts get a small recency
    /// boost so they can beat week-old locked constraints when both match.
    package static func rankingAdjustedScore(
        _ hit: Hit,
        nowMs: Int64,
        query: String?,
        liveCheckout: GitCheckoutSnapshot? = nil
    ) -> Float {
        var score = freshnessAdjustedScore(hit, nowMs: nowMs)
        let checkoutRelation = hit.metadata[MemoryMetadataKeys.onThisTree].flatMap(OnThisTree.init(rawValue:))
            ?? liveCheckout.map { live in
                MemorySemantics.classifyCheckout(
                    storedSHA: hit.metadata[MemoryMetadataKeys.gitSHA],
                    live: live
                )
            }
        if let checkoutRelation, checkoutRelation == .other || checkoutRelation == .unknown,
           MemorySemantics.looksLandedClaim(metadata: hit.metadata, text: hit.text) {
            score -= 0.25
        }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if looksScorecard(hit.text), !queryAsksForRating(trimmedQuery) {
            score -= scorecardRankPenalty
        }
        guard !trimmedQuery.isEmpty else { return score }

        let queryLooksLikeStaleLookup = isStaleIgnoreList(trimmedQuery)
        let isLocked = hit.metadata[MemoryMetadataKeys.durability] == MemoryDurability.locked.rawValue
        if isLocked, isStaleIgnoreList(hit.text), !queryLooksLikeStaleLookup {
            score -= 0.28
        }

        let type = MemoryType(rawValue: hit.metadata[MemoryMetadataKeys.type] ?? "")
        let isStanding = switch type {
        case .userPreference, .decision, .lesson, .constraint, .fact: true
        case .note, .taskState, .handoff, nil: false
        }
        if isStanding, hit.timestampMs > 0, nowMs > hit.timestampMs {
            let ageDays = Float(nowMs - hit.timestampMs) / 86_400_000
            if ageDays < 7 {
                score += 0.20
            } else if ageDays > 14 {
                score -= 0.12
            }
        }
        return score
    }

    package static func isStaleIgnoreList(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("do not follow") || lowered.contains("stale frames")
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
        let filtered = filterHitsByProject(merged, project: identity.project, repo: identity.repo)
        if filtered.isEmpty {
            if identity.project == nil && identity.repo == nil {
                return (
                    [],
                    true,
                    "no frames for project (unresolved); pass project/repo or scope=global",
                    .empty
                )
            }
            let label = identity.project.map { "project \($0)" }
                ?? identity.repo.map { "repo \($0)" }
                ?? "project"
            return ([], true, "no frames for \(label)", .empty)
        }
        if identity.project == nil && identity.repo == nil {
            // Unresolved project keeps the live session and unstamped durable;
            // stamped foreign durable was already dropped by the filter.
            return (filtered, false, nil, .empty)
        }
        return (filtered, false, nil, louderDropped(merged: merged, kept: filtered, identity: identity))
    }

    /// Exact `wax.project` / `wax.repo` match, same as `frameFilterForScopedRetrieval`.
    /// Unlabeled frames do not occupy a named project (retrieval would drop them).
    package static func metadataMatchesScopedRetrieval(
        _ metadata: [String: String],
        identity: Identity
    ) -> Bool {
        if let project = identity.project {
            guard metadata[MemoryMetadataKeys.project] == project else { return false }
        }
        if let repo = identity.repo {
            guard metadata[MemoryMetadataKeys.repo] == repo else { return false }
        }
        return identity.project != nil || identity.repo != nil
    }

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

    /// Foreign hits scoring ≥ the kept top. Empty-lane miss stays `projectMiss`; never auto-widens.
    private static func louderDropped(
        merged: [Hit],
        kept: [Hit],
        identity: Identity
    ) -> ScopeDropped {
        let maxKept = kept.map(\.score).max()
        let foreign = merged.filter { hit in
            filterHitsByProject([hit], project: identity.project, repo: identity.repo).isEmpty
        }
        let louder = foreign.filter { hit in
            maxKept.map { hit.score >= $0 } ?? true
        }
        guard !louder.isEmpty else { return .empty }
        let ranked = louder.sorted(by: higherRank)
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
            hint: "retry explicitly with scope=global"
        )
    }

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
