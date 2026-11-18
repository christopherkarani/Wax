import Foundation

extension MemorySemantics {
    package static func rankingReasons(
        metadata: [String: String],
        scope: MemoryScopeContext?,
        nowMs: Int64
    ) -> (adjustment: Float, reasons: [String]) {
        let info = parse(metadata: metadata, nowMs: nowMs)
        if info.isExpired {
            return (-10, ["expired memory"])
        }

        var adjustment: Float = 0
        var reasons: [String] = []

        if let scope, let repo = info.repo, repo == scope.repoName {
            adjustment += 0.9
            reasons.append("same repo")
        }
        if let scope, let project = info.project, project == scope.projectName {
            adjustment += 0.7
            reasons.append("same project")
        }

        switch info.type {
        case .decision:
            adjustment += 0.45
            reasons.append("decision memory")
        case .userPreference:
            adjustment += 0.50
            reasons.append("user preference")
        case .lesson:
            adjustment += 0.40
            reasons.append("lesson memory")
        case .constraint:
            adjustment += 0.45
            reasons.append("constraint memory")
        case .handoff:
            if let createdAtMs = info.createdAtMs {
                let ageDays = max(0, nowMs - createdAtMs) / (1000 * 60 * 60 * 24)
                if ageDays <= 3 {
                    adjustment += 0.80
                    reasons.append("recent handoff")
                } else if ageDays <= 14 {
                    adjustment += 0.20
                    reasons.append("handoff")
                } else {
                    adjustment -= 0.40
                    reasons.append("stale handoff")
                }
            } else {
                adjustment += 0.10
                reasons.append("handoff without timestamp")
            }
        case .taskState:
            if let createdAtMs = info.createdAtMs {
                let ageHours = max(0, nowMs - createdAtMs) / (1000 * 60 * 60)
                if ageHours <= 48 {
                    adjustment += 0.50
                    reasons.append("recent task state")
                } else if ageHours > 24 * 7 {
                    adjustment -= 0.60
                }
            }
        case .fact:
            adjustment += 0.35
            reasons.append("durable fact")
        case .note:
            break
        }

        switch info.durability {
        case .locked:
            adjustment += 0.60
            reasons.append("locked durable")
        case .durable:
            adjustment += 0.25
            reasons.append("durable")
        case .working:
            adjustment += 0.05
        case .ephemeral:
            adjustment -= 0.10
        }

        if let confidence = info.confidence {
            if confidence >= 0.85 {
                adjustment += 0.20
                reasons.append("high confidence")
            } else if confidence < 0.45 {
                adjustment -= 0.20
            }
        }

        if let createdAtMs = info.createdAtMs {
            let ageDays = max(0, nowMs - createdAtMs) / (1000 * 60 * 60 * 24)
            if ageDays <= 3 {
                adjustment += 0.15
                reasons.append("recent")
            } else if ageDays > 90, info.durability != .durable, info.durability != .locked {
                adjustment -= 0.35
            }
        }

        return (adjustment, reasons)
    }

    package static func accessReasons(
        stats: FrameAccessStats?,
        metadata: [String: String] = [:],
        nowMs: Int64
    ) -> (adjustment: Float, reasons: [String]) {
        guard let stats else { return (0, []) }
        var adjustment = AccessFrequencyRanker.rawAdjustment(stats: stats, nowMs: nowMs)

        // Durable and locked memories remain governed by their stronger
        // semantic policy. Access history may reinforce them, but stale access
        // must not demote an explicitly durable/locked record.
        let durability = parse(metadata: metadata, nowMs: nowMs).durability
        if adjustment < 0, durability == .durable || durability == .locked {
            adjustment = 0
        }

        var reasons: [String] = []
        let rankingCount = stats.engagementCount
        let rankingLast = stats.lastEngagementMs > 0 ? stats.lastEngagementMs : stats.firstAccessMs
        let cappedCount = min(rankingCount, 32)
        if cappedCount >= 3 {
            reasons.append("repeated use")
        }
        let hoursSinceAccess = max(0, nowMs - rankingLast) / (1000 * 60 * 60)
        if hoursSinceAccess <= 24 {
            reasons.append("recently used")
        }
        if adjustment < 0 {
            reasons.append("stale access")
        } else if adjustment > 0, reasons.isEmpty {
            reasons.append("access frequency boost")
        }
        return (adjustment, reasons)
    }

    package static func classifyCandidate(text: String, metadata: [String: String]) -> MemoryType {
        // Implicit `note` is the default stamp for unclassified session writes.
        // Treat it like `task_state`: ignore the stored type so text cues such as
        // "Decision:" can still promote. Explicit types stay trusted.
        if let raw = metadata[MemoryMetadataKeys.type],
           let typed = MemoryType(rawValue: raw),
           typed != .taskState,
           typed != .note {
            return typed
        }
        let lower = text.lowercased()
        if lower.contains("decision:") || lower.contains("decided") {
            return .decision
        }
        if lower.contains("lesson:") || lower.contains("learned") || lower.contains("fix:") {
            return .lesson
        }
        if lower.contains("prefer") || lower.contains("preference") {
            return .userPreference
        }
        if lower.contains("constraint") || lower.contains("must ") || lower.contains("requirement") {
            return .constraint
        }
        if lower.contains("handoff") {
            return .handoff
        }
        if let raw = metadata[MemoryMetadataKeys.type], let typed = MemoryType(rawValue: raw) {
            return typed
        }
        if metadata["session_id"] != nil {
            return .taskState
        }
        return .note
    }

    package static func summarizeCandidate(_ text: String, maxLength: Int = 220) -> String {
        let normalized = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
