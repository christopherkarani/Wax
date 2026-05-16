import Foundation
import WaxCore

package struct BrokerPromotionDuplicate: Sendable, Equatable {
    package var frameId: UInt64
    package var similarity: Float
    package var summary: String
    package var memoryType: MemoryType
}

package struct BrokerPromotionProposal: Sendable, Equatable {
    package var content: String
    package var summary: String
    package var suggestedType: MemoryType
    package var suggestedDurability: MemoryDurability
    package var confidence: Float
    package var recallCount: Int
    package var uniqueQueryCount: Int
    package var lastRetrievedAtMs: Int64?
    package var averageRelevanceScore: Float
    package var duplicateMatches: [BrokerPromotionDuplicate]
    package var shouldWrite: Bool
    package var reasons: [String]
}

package struct BrokerSessionSynthesis: Sendable, Equatable {
    package var summary: String
    package var handoff: String
    package var lessons: [String]
    package var decisions: [String]
    package var preferences: [String]
    package var constraints: [String]
    package var durableCandidates: [BrokerPromotionProposal]
}

package struct BrokerPromotionSettings: Sendable, Equatable {
    package static let maxCandidateLimit = 12

    package var minimumConfidence: Float
    package var minimumRecallCount: Int
    package var maxCandidates: Int

    package static let `default` = BrokerPromotionSettings(
        minimumConfidence: 0.72,
        minimumRecallCount: 0,
        maxCandidates: 6
    )

    package static func fromEnvironment() -> BrokerPromotionSettings {
        let env = ProcessInfo.processInfo.environment
        let minimumConfidence = env["WAX_OPENCLAW_PROMOTION_MIN_CONFIDENCE"]
            .flatMap(Float.init)
            .map { min(max($0, 0), 1) }
            ?? Self.default.minimumConfidence
        let minimumRecallCount = env["WAX_OPENCLAW_PROMOTION_MIN_RECALL_COUNT"]
            .flatMap(Int.init)
            .map { max(0, $0) }
            ?? Self.default.minimumRecallCount
        let maxCandidates = env["WAX_OPENCLAW_PROMOTION_MAX_CANDIDATES"]
            .flatMap(Int.init)
            .map { min(max(1, $0), Self.maxCandidateLimit) }
            ?? Self.default.maxCandidates
        return BrokerPromotionSettings(
            minimumConfidence: minimumConfidence,
            minimumRecallCount: minimumRecallCount,
            maxCandidates: maxCandidates
        )
    }
}

package struct BrokerHealthDuplicatePair: Sendable, Equatable {
    package var leftFrameId: UInt64
    package var rightFrameId: UInt64
    package var similarity: Float
}

package struct BrokerMemoryHealth: Sendable, Equatable {
    package var totalDocuments: Int
    package var typedCounts: [String: Int]
    package var expiredFrameIds: [UInt64]
    package var staleFrameIds: [UInt64]
    package var lowHitFrameIds: [UInt64]
    package var duplicatePairs: [BrokerHealthDuplicatePair]
    package var contradictionSummaries: [String]
}

package enum BrokerMemoryInsights {
    package static func proposePromotion(
        content: String,
        metadata: [String: String],
        sessionID: UUID?,
        sourceFrameID: UInt64?,
        scope: MemoryScopeContext?,
        longTermDocuments: [MemoryOrchestrator.CorpusSourceDocument],
        recallSignals: BrokerSessionRecallSignals? = nil,
        settings: BrokerPromotionSettings = .default
    ) -> BrokerPromotionProposal {
        let suggestedType = MemorySemantics.classifyCandidate(text: content, metadata: metadata)
        let suggestedDurability = MemorySemantics.defaultDurability(for: suggestedType)
        let summary = MemorySemantics.summarizeCandidate(content)
        let duplicates = longTermDocuments
            .map { document -> BrokerPromotionDuplicate? in
                let score = MemorySemantics.similarity(lhs: content, rhs: document.text)
                guard score >= 0.45 else { return nil }
                return BrokerPromotionDuplicate(
                    frameId: document.frameId,
                    similarity: score,
                    summary: MemorySemantics.summarizeCandidate(document.text),
                    memoryType: MemorySemantics.classifyCandidate(text: document.text, metadata: document.metadata)
                )
            }
            .compactMap { $0 }
            .sorted { lhs, rhs in
                if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
                return lhs.frameId < rhs.frameId
            }
        let exactDuplicate = duplicates.first?.similarity ?? 0 >= 0.92

        var reasons = [String]()
        if let scope, metadata[MemoryMetadataKeys.repo] == scope.repoName || metadata[MemoryMetadataKeys.project] == scope.projectName {
            reasons.append("matches current repo scope")
        }
        if let sourceFrameID {
            reasons.append("promoted from session frame \(sourceFrameID)")
        } else if sessionID != nil {
            reasons.append("promoted from session memory")
        }
        switch suggestedType {
        case .decision:
            reasons.append("decision-like content")
        case .lesson:
            reasons.append("lesson-like content")
        case .userPreference:
            reasons.append("preference-like content")
        case .constraint:
            reasons.append("constraint-like content")
        case .fact:
            reasons.append("fact-like content")
        case .taskState:
            reasons.append("task state should be reviewed before promotion")
        case .handoff:
            reasons.append("handoff captured for cross-session continuity")
        case .note:
            reasons.append("general note")
        }
        if exactDuplicate {
            reasons.append("near-exact duplicate already exists")
        } else if let first = duplicates.first {
            reasons.append("related durable memory exists (\(Int(first.similarity * 100))% similar)")
        }
        if let recallSignals {
            if recallSignals.recallCount > 0 {
                reasons.append("recalled \(recallSignals.recallCount)x")
            }
            if recallSignals.uniqueQueryCount > 0 {
                reasons.append("seen across \(recallSignals.uniqueQueryCount) unique queries")
            }
            if recallSignals.lastRetrievedAtMs != nil {
                reasons.append("recently retrieved in session flow")
            }
            if recallSignals.averageScore > 0 {
                reasons.append(String(format: "average relevance %.3f", recallSignals.averageScore))
            }
        }

        let recallBoost = min(0.16, Float(recallSignals?.recallCount ?? 0) * 0.03)
        let diversityBoost = min(0.12, Float(recallSignals?.uniqueQueryCount ?? 0) * 0.04)
        let relevanceBoost = min(0.12, max(0, (recallSignals?.averageScore ?? 0) - 0.2) * 0.2)

        let recallCount = recallSignals?.recallCount ?? 0
        let confidence = min(
            0.97,
            max(
                0.40,
                baseConfidence(for: suggestedType)
                    + min(0.15, Float(max(0, duplicates.count - (exactDuplicate ? 1 : 0))) * 0.02)
                    + recallBoost
                    + diversityBoost
                    + relevanceBoost
            )
        )
        let isAlwaysPromotableType =
            suggestedType == .decision
                || suggestedType == .lesson
                || suggestedType == .userPreference
                || suggestedType == .constraint
                || suggestedType == .fact
        let meetsThreshold = confidence >= settings.minimumConfidence && recallCount >= settings.minimumRecallCount
        if !isAlwaysPromotableType {
            reasons.append(String(format: "requires confidence >= %.2f", settings.minimumConfidence))
            if settings.minimumRecallCount > 0 {
                reasons.append("requires >=\(settings.minimumRecallCount) recalls")
            }
        }
        let shouldWrite = !exactDuplicate && (isAlwaysPromotableType || meetsThreshold)

        return BrokerPromotionProposal(
            content: content,
            summary: summary,
            suggestedType: suggestedType,
            suggestedDurability: suggestedDurability,
            confidence: confidence,
            recallCount: recallCount,
            uniqueQueryCount: recallSignals?.uniqueQueryCount ?? 0,
            lastRetrievedAtMs: recallSignals?.lastRetrievedAtMs,
            averageRelevanceScore: recallSignals?.averageScore ?? 0,
            duplicateMatches: Array(duplicates.prefix(5)),
            shouldWrite: shouldWrite,
            reasons: reasons
        )
    }

    package static func synthesizeSession(
        documents: [MemoryOrchestrator.CorpusSourceDocument],
        scope: MemoryScopeContext?,
        longTermDocuments: [MemoryOrchestrator.CorpusSourceDocument],
        recallSignalsByFrameID: [UInt64: BrokerSessionRecallSignals] = [:],
        settings: BrokerPromotionSettings = .default
    ) -> BrokerSessionSynthesis {
        let ordered = documents.sorted { lhs, rhs in
            if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
            return lhs.frameId > rhs.frameId
        }

        let summaries = ordered.prefix(4).map { MemorySemantics.summarizeCandidate($0.text, maxLength: 160) }
        let summary = summaries.isEmpty ? "No session memories recorded." : summaries.joined(separator: " | ")

        var lessons: [String] = []
        var decisions: [String] = []
        var preferences: [String] = []
        var constraints: [String] = []
        var candidateMap: [String: BrokerPromotionProposal] = [:]

        for document in ordered {
            let proposal = proposePromotion(
                content: document.text,
                metadata: document.metadata,
                sessionID: document.metadata["session_id"].flatMap(UUID.init(uuidString:)),
                sourceFrameID: document.frameId,
                scope: scope,
                longTermDocuments: longTermDocuments,
                recallSignals: recallSignalsByFrameID[document.frameId],
                settings: settings
            )
            switch proposal.suggestedType {
            case .lesson:
                lessons.append(proposal.summary)
            case .decision:
                decisions.append(proposal.summary)
            case .userPreference:
                preferences.append(proposal.summary)
            case .constraint:
                constraints.append(proposal.summary)
            default:
                break
            }
            guard proposal.suggestedType != .taskState else { continue }
            let fingerprint = MemorySemantics.normalizedTextFingerprint(proposal.summary)
            if candidateMap[fingerprint] == nil {
                candidateMap[fingerprint] = proposal
            }
        }

        let durableCandidates = candidateMap.values
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.summary < rhs.summary
            }
            .prefix(settings.maxCandidates)

        let handoffComponents = Array(ordered.prefix(3)).map { MemorySemantics.summarizeCandidate($0.text, maxLength: 180) }
        let handoff = handoffComponents.isEmpty
            ? "No actionable session handoff available."
            : handoffComponents.joined(separator: "\n")

        return BrokerSessionSynthesis(
            summary: summary,
            handoff: handoff,
            lessons: dedupeStrings(lessons, limit: 5),
            decisions: dedupeStrings(decisions, limit: 5),
            preferences: dedupeStrings(preferences, limit: 5),
            constraints: dedupeStrings(constraints, limit: 5),
            durableCandidates: Array(durableCandidates)
        )
    }

    package static func healthReport(
        documents: [MemoryOrchestrator.CorpusSourceDocument],
        accessStats: [UInt64: FrameAccessStats],
        facts: StructuredFactsResult?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> BrokerMemoryHealth {
        var typedCounts: [String: Int] = [:]
        var expired: [UInt64] = []
        var stale: [UInt64] = []
        var lowHit: [UInt64] = []

        for document in documents {
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: nowMs)
            typedCounts[info.type.rawValue, default: 0] += 1
            if info.isExpired {
                expired.append(document.frameId)
            }
            if let createdAtMs = info.createdAtMs {
                let ageDays = max(0, nowMs - createdAtMs) / (1000 * 60 * 60 * 24)
                if ageDays > 30, info.durability == .working || info.durability == .ephemeral {
                    stale.append(document.frameId)
                }
                if let stat = accessStats[document.frameId], ageDays > 14, stat.accessCount <= 1 {
                    lowHit.append(document.frameId)
                }
            }
        }

        let duplicatePairs = duplicateCandidates(in: documents)
        let contradictionSummaries = contradictionHints(from: facts)

        return BrokerMemoryHealth(
            totalDocuments: documents.count,
            typedCounts: typedCounts,
            expiredFrameIds: expired.sorted(),
            staleFrameIds: stale.sorted(),
            lowHitFrameIds: lowHit.sorted(),
            duplicatePairs: duplicatePairs,
            contradictionSummaries: contradictionSummaries
        )
    }

    private static func duplicateCandidates(
        in documents: [MemoryOrchestrator.CorpusSourceDocument],
        comparisonLimit: Int = 140
    ) -> [BrokerHealthDuplicatePair] {
        let limited = Array(documents.prefix(comparisonLimit))
        guard limited.count > 1 else { return [] }
        var pairs: [BrokerHealthDuplicatePair] = []
        for lhsIndex in limited.indices {
            for rhsIndex in limited.indices where rhsIndex > lhsIndex {
                let lhs = limited[lhsIndex]
                let rhs = limited[rhsIndex]
                let similarity = MemorySemantics.similarity(lhs: lhs.text, rhs: rhs.text)
                guard similarity >= 0.88 else { continue }
                pairs.append(
                    BrokerHealthDuplicatePair(
                        leftFrameId: lhs.frameId,
                        rightFrameId: rhs.frameId,
                        similarity: similarity
                    )
                )
            }
        }
        return pairs.sorted { lhs, rhs in
            if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
            if lhs.leftFrameId != rhs.leftFrameId { return lhs.leftFrameId < rhs.leftFrameId }
            return lhs.rightFrameId < rhs.rightFrameId
        }
    }

    private static func contradictionHints(from facts: StructuredFactsResult?) -> [String] {
        guard let facts else { return [] }
        var buckets: [String: Set<String>] = [:]
        for hit in facts.hits where hit.isOpenEnded {
            let key = "\(hit.fact.subject.rawValue)|\(hit.fact.predicate.rawValue)"
            buckets[key, default: []].insert(factValueSummary(hit.fact.object))
        }
        return buckets.compactMap { key, values in
            guard values.count > 1 else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let subject = parts.first ?? "unknown"
            let predicate = parts.count > 1 ? parts[1] : "unknown"
            return "\(subject) has multiple current '\(predicate)' values: \(values.sorted().joined(separator: ", "))"
        }.sorted()
    }

    private static func factValueSummary(_ value: FactValue) -> String {
        switch value {
        case .string(let text):
            return text
        case .int(let number):
            return String(number)
        case .double(let number):
            return String(number)
        case .bool(let value):
            return value ? "true" : "false"
        case .entity(let key):
            return key.rawValue
        case .timeMs(let ms):
            return String(ms)
        case .data(let data):
            return "data(\(data.count)b)"
        }
    }

    private static func baseConfidence(for type: MemoryType) -> Float {
        switch type {
        case .decision, .constraint:
            return 0.80
        case .lesson, .fact:
            return 0.76
        case .userPreference:
            return 0.78
        case .handoff:
            return 0.66
        case .note:
            return 0.55
        case .taskState:
            return 0.48
        }
    }

    private static func dedupeStrings(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var deduped: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            deduped.append(normalized)
            if deduped.count >= limit { break }
        }
        return deduped
    }
}
