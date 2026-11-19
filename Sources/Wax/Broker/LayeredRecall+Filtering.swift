import Foundation
import WaxCore

extension LayeredRecall {
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

    /// Most ended-session stores one recall or search opens, newest first.
    package static let maxEpisodicStores = 6

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
}
