import Foundation
import WaxCore

extension LayeredRecall {
    package static let recallClusterJaccardThreshold: Float = 0.55
    package static let scorecardRankPenalty: Float = 0.40
    package static let unlandedSkipListPenalty: Float = 0.40
    /// Lexical current-session hits rank ahead of durable neighbors.
    package static let sessionLexicalBoost: Float = 0.12
    /// A landed claim recorded on another (or unknown) checkout.
    package static let offTreeLandedClaimPenalty: Float = 0.25
    /// Locked "do not follow / stale frames" lists outside a stale lookup.
    package static let lockedStaleIgnoreListPenalty: Float = 0.28
    /// Standing memory younger than ``freshStandingMaxAgeDays``.
    package static let freshStandingBoost: Float = 0.20
    /// Standing memory older than ``agedStandingMinAgeDays``.
    package static let agedStandingPenalty: Float = 0.12
    package static let freshStandingMaxAgeDays: Float = 7
    package static let agedStandingMinAgeDays: Float = 14
    /// Maximum recency penalty for operational memory, reached at
    /// ``operationalFreshnessWindowDays``.
    package static let operationalFreshnessMaxPenalty: Float = 0.18
    package static let operationalFreshnessWindowDays: Float = 30

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
                copy.score += sessionLexicalBoost
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
        let candidates = demoteStaleNearTwins(tagged.map { demoteUnlandedSkipList($0, unlandedIDs: unlandedIDs) })
        let ranked = candidates.sorted(by: higherRank)
        let clustered = clusterHits(ranked, identity: identity)
        var seen = Set<String>()
        var merged: [Hit] = []
        // Default queries drop explicit session rubrics (oracle: absent unless
        // asked). A bare "NN/100" is only demoted (−0.40 in rankingAdjustedScore)
        // because real memories say "99/100 tests pass".
        for hit in clustered.sorted(by: higherRank) {
            if looksSessionRubric(hit.text), !queryAsks { continue }
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

    /// Rating-shaped text: a "NN/100" figure or a session rubric. Demoted in
    /// ranking unless the query asks for a rating; only rubrics are dropped.
    package static func looksScorecard(_ text: String) -> Bool {
        if isStaleIgnoreList(text) { return false }
        let lowered = text.lowercased()
        let ratingDump = lowered.range(of: #"\b\d{1,3}\s*/\s*100\b"#, options: .regularExpression) != nil
        return ratingDump || looksSessionRubric(text)
    }

    /// Explicit end-of-session rating ("… for this session; would use it again").
    package static func looksSessionRubric(_ text: String) -> Bool {
        if isStaleIgnoreList(text) { return false }
        let lowered = text.lowercased()
        return lowered.contains("for this session") && lowered.contains("would use it again")
    }

    /// Whole-word "rating(s)", "score(s)", "scorecard(s)", "scored". Substrings
    /// such as "underscore" or "scoreboard" do not count.
    package static func queryAsksForRating(_ query: String?) -> Bool {
        let lowered = query?.lowercased() ?? ""
        guard !lowered.isEmpty else { return false }
        return lowered.range(
            of: #"\b(ratings?|scores?|scored|scorecards?)\b"#,
            options: .regularExpression
        ) != nil
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

    private static let skipRerunPhrases = ["do not re-run", "don't re-run", "do not rerun"]
    private static let skipReproposePhrases = ["do not re-propose", "don't re-propose"]

    package static func looksSkipThisSession(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return skipRerunPhrases.contains { lowered.contains($0) } && lowered.contains("this session")
    }

    package static func looksSkipList(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return (skipRerunPhrases + skipReproposePhrases).contains { lowered.contains($0) }
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

    package static let staleTwinRankPenalty: Float = 0.15
    package static let staleTwinExplanation = "stale near-twin demoted"

    /// Older half of a same-type near-twin pair that auto-supersede missed
    /// (written before the write-time pass, or across lanes) reads stale: a
    /// newer frame says nearly the same thing. Demote it so the newer twin
    /// wins the rank without a store rewrite. Locked frames stay protected.
    package static func demoteStaleNearTwins(_ hits: [Hit]) -> [Hit] {
        let signatures = hits.map { MemorySemantics.TextSignature($0.text) }
        return hits.indices.map { index in
            let hit = hits[index]
            guard !isLockedHit(hit), hasNewerNearTwin(at: index, in: hits, signatures: signatures) else {
                return hit
            }
            var copy = hit
            copy.score -= staleTwinRankPenalty
            if !copy.explanations.contains(staleTwinExplanation) {
                copy.explanations.append(staleTwinExplanation)
            }
            return copy
        }
    }

    private static func hasNewerNearTwin(
        at index: Int,
        in hits: [Hit],
        signatures: [MemorySemantics.TextSignature]
    ) -> Bool {
        let hit = hits[index]
        let type = hit.metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue
        let project = hit.metadata[MemoryMetadataKeys.project].flatMap { $0.isEmpty ? nil : $0 }
        return hits.indices.contains { otherIndex in
            let other = hits[otherIndex]
            guard other.id != hit.id else { return false }
            guard (other.metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue) == type else {
                return false
            }
            let otherProject = other.metadata[MemoryMetadataKeys.project].flatMap { $0.isEmpty ? nil : $0 }
            guard otherProject == project else { return false }
            guard isNewerTwin(other, than: hit) else { return false }
            return MemorySemantics.isStaleTwin(older: signatures[index], newer: signatures[otherIndex])
        }
    }

    private static func isNewerTwin(_ other: Hit, than hit: Hit) -> Bool {
        if other.timestampMs != hit.timestampMs {
            return other.timestampMs > hit.timestampMs
        }
        return other.horizon == hit.horizon && other.frameID > hit.frameID
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
        let penalty = min(
            operationalFreshnessMaxPenalty,
            max(0, ageDays / operationalFreshnessWindowDays) * operationalFreshnessMaxPenalty
        )
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
            score -= offTreeLandedClaimPenalty
        }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if looksScorecard(hit.text), !queryAsksForRating(trimmedQuery) {
            score -= scorecardRankPenalty
        }
        guard !trimmedQuery.isEmpty else { return score }

        let queryLooksLikeStaleLookup = isStaleIgnoreList(trimmedQuery)
        let isLocked = hit.metadata[MemoryMetadataKeys.durability] == MemoryDurability.locked.rawValue
        if isLocked, isStaleIgnoreList(hit.text), !queryLooksLikeStaleLookup {
            score -= lockedStaleIgnoreListPenalty
        }

        let type = MemoryType(rawValue: hit.metadata[MemoryMetadataKeys.type] ?? "")
        let isStanding = switch type {
        case .userPreference, .decision, .lesson, .constraint, .fact: true
        case .note, .taskState, .handoff, nil: false
        }
        if isStanding, hit.timestampMs > 0, nowMs > hit.timestampMs {
            let ageDays = Float(nowMs - hit.timestampMs) / 86_400_000
            if ageDays < freshStandingMaxAgeDays {
                score += freshStandingBoost
            } else if ageDays > agedStandingMinAgeDays {
                score -= agedStandingPenalty
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
}
