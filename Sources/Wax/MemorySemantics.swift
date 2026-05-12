import Foundation

public enum MemoryType: String, CaseIterable, Sendable {
    case note = "note"
    case taskState = "task_state"
    case userPreference = "user_preference"
    case decision = "decision"
    case lesson = "lesson"
    case handoff = "handoff"
    case constraint = "constraint"
    case fact = "fact"
}

public enum MemoryDurability: String, CaseIterable, Sendable {
    case ephemeral = "ephemeral"
    case working = "working"
    case durable = "durable"
    case locked = "locked"
}

public struct MemoryScopeContext: Sendable, Equatable {
    public var cwdPath: String?
    public var repoRootPath: String?
    public var repoName: String?
    public var projectName: String?

    public init(
        cwdPath: String? = nil,
        repoRootPath: String? = nil,
        repoName: String? = nil,
        projectName: String? = nil
    ) {
        self.cwdPath = cwdPath
        self.repoRootPath = repoRootPath
        self.repoName = repoName
        self.projectName = projectName
    }
}

package struct MemorySemanticInfo: Sendable, Equatable {
    package var type: MemoryType
    package var durability: MemoryDurability
    package var project: String?
    package var repo: String?
    package var createdAtMs: Int64?
    package var expiresAtMs: Int64?
    package var confidence: Float?
    package var isReviewed: Bool
    package var isExpired: Bool
}

package struct MemoryWriteSemantics: Sendable, Equatable {
    package var type: MemoryType?
    package var durability: MemoryDurability?
    package var project: String?
    package var repo: String?
    package var confidence: Float?
    package var expiresInDays: Int?
    package var reviewed: Bool
    package var lock: Bool

    package init(
        type: MemoryType? = nil,
        durability: MemoryDurability? = nil,
        project: String? = nil,
        repo: String? = nil,
        confidence: Float? = nil,
        expiresInDays: Int? = nil,
        reviewed: Bool = false,
        lock: Bool = false
    ) {
        self.type = type
        self.durability = durability
        self.project = project
        self.repo = repo
        self.confidence = confidence
        self.expiresInDays = expiresInDays
        self.reviewed = reviewed
        self.lock = lock
    }
}

package enum MemoryMetadataKeys {
    package static let type = "wax.memory_type"
    package static let durability = "wax.durability"
    package static let project = "wax.project"
    package static let repo = "wax.repo"
    package static let createdAtMs = "wax.created_at_ms"
    package static let expiresAtMs = "wax.expires_at_ms"
    package static let confidence = "wax.confidence"
    package static let reviewed = "wax.reviewed"
    package static let promotedFromSession = "wax.promoted_from_session"
    package static let promotedFromFrame = "wax.promoted_from_frame"
    package static let duplicateOfFrame = "wax.duplicate_of_frame"
    package static let sourcePath = "wax.source_path"
    package static let sourceLine = "wax.source_line"
    package static let sourceHash = "wax.source_hash"
    package static let sourceKind = "wax.source_kind"
    package static let sourceDate = "wax.source_date"
    package static let sourceMemoryID = "wax.source_memory_id"
    package static let sourceManaged = "wax.source_managed"
}

package enum SecretHeuristics {
    package static func detectSecretLikeContent(_ text: String, metadata: [String: String] = [:]) -> String? {
        let combined = ([text] + metadata.map { "\($0.key)=\($0.value)" }).joined(separator: "\n")
        if combined.contains("-----BEGIN ") && combined.contains("PRIVATE KEY-----") {
            return "private key material"
        }
        if firstMatch(#"AKIA[0-9A-Z]{16}"#, in: combined) != nil {
            return "AWS access key"
        }
        if firstMatch(#"github_pat_[A-Za-z0-9_]{20,}"#, in: combined) != nil {
            return "GitHub personal access token"
        }
        if firstMatch(#"\bsk-[A-Za-z0-9]{20,}\b"#, in: combined) != nil {
            return "OpenAI-style API key"
        }
        if firstMatch(#"\bxox[pbar]-[A-Za-z0-9-]{20,}\b"#, in: combined) != nil {
            return "Slack token"
        }
        if firstMatch(#"(?i)\b(bearer|token|api[_-]?key|secret|password)\b\s*[:=]\s*['"]?[A-Za-z0-9_\-\/+=]{12,}"#, in: combined) != nil {
            return "credential assignment"
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}

package enum MemorySemantics {
    package static func inferScopeContext(currentDirectoryPath: String = FileManager.default.currentDirectoryPath) -> MemoryScopeContext {
        let cwdURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true).standardizedFileURL
        guard let repoRoot = gitRepositoryRoot(startingAt: cwdURL) else {
            return MemoryScopeContext(cwdPath: cwdURL.path)
        }
        let repoName = repoRoot.lastPathComponent
        return MemoryScopeContext(
            cwdPath: cwdURL.path,
            repoRootPath: repoRoot.path,
            repoName: repoName,
            projectName: repoName
        )
    }

    package static func normalizeWriteMetadata(
        metadata: [String: String],
        semantics: MemoryWriteSemantics,
        sessionID: UUID?,
        inferredScope: MemoryScopeContext?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [String: String] {
        var normalized = metadata
        let resolvedType = semantics.type ?? defaultMemoryType(sessionID: sessionID, existing: metadata)
        let resolvedDurability = semantics.lock
            ? MemoryDurability.locked
            : semantics.durability ?? defaultDurability(for: resolvedType)

        normalized[MemoryMetadataKeys.type] = resolvedType.rawValue
        normalized[MemoryMetadataKeys.durability] = resolvedDurability.rawValue
        normalized[MemoryMetadataKeys.createdAtMs] = normalized[MemoryMetadataKeys.createdAtMs] ?? String(nowMs)

        if normalized["session_id"] == nil, let sessionID {
            normalized["session_id"] = sessionID.uuidString
        }

        if let project = normalizedOrNil(semantics.project) ?? normalizedOrNil(normalized[MemoryMetadataKeys.project]) ?? normalizedOrNil(inferredScope?.projectName) {
            normalized[MemoryMetadataKeys.project] = project
        }
        if let repo = normalizedOrNil(semantics.repo) ?? normalizedOrNil(normalized[MemoryMetadataKeys.repo]) ?? normalizedOrNil(inferredScope?.repoName) {
            normalized[MemoryMetadataKeys.repo] = repo
        }
        if let confidence = semantics.confidence {
            normalized[MemoryMetadataKeys.confidence] = String(max(0, min(confidence, 1)))
        }
        if semantics.reviewed {
            normalized[MemoryMetadataKeys.reviewed] = "true"
        } else if normalized[MemoryMetadataKeys.reviewed] == nil, resolvedDurability == .durable || resolvedDurability == .locked {
            normalized[MemoryMetadataKeys.reviewed] = "false"
        }
        if let expiresInDays = semantics.expiresInDays, expiresInDays > 0 {
            let expiresAtMs = nowMs + Int64(expiresInDays) * 24 * 60 * 60 * 1000
            normalized[MemoryMetadataKeys.expiresAtMs] = String(expiresAtMs)
        }
        return normalized
    }

    package static func approvedPromotionMetadata(
        metadata: [String: String],
        semantics: MemoryWriteSemantics,
        suggestedType: MemoryType,
        suggestedDurability: MemoryDurability,
        suggestedConfidence: Float
    ) -> [String: String] {
        var approved = metadata
        approved[MemoryMetadataKeys.type] = (semantics.type ?? suggestedType).rawValue
        let resolvedDurability = semantics.lock
            ? MemoryDurability.locked
            : semantics.durability ?? suggestedDurability
        approved[MemoryMetadataKeys.durability] = resolvedDurability.rawValue
        if approved[MemoryMetadataKeys.confidence] == nil {
            approved[MemoryMetadataKeys.confidence] = String(suggestedConfidence)
        }
        approved[MemoryMetadataKeys.reviewed] = "true"
        return approved
    }

    package static func parse(metadata: [String: String], nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> MemorySemanticInfo {
        let type = MemoryType(rawValue: metadata[MemoryMetadataKeys.type] ?? "") ?? .note
        let durability = MemoryDurability(rawValue: metadata[MemoryMetadataKeys.durability] ?? "") ?? defaultDurability(for: type)
        let createdAtMs = metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init)
        let expiresAtMs = metadata[MemoryMetadataKeys.expiresAtMs].flatMap(Int64.init)
        let confidence = metadata[MemoryMetadataKeys.confidence].flatMap(Float.init)
        let reviewed = metadata[MemoryMetadataKeys.reviewed]?.lowercased() == "true"
        return MemorySemanticInfo(
            type: type,
            durability: durability,
            project: normalizedOrNil(metadata[MemoryMetadataKeys.project]),
            repo: normalizedOrNil(metadata[MemoryMetadataKeys.repo]),
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            confidence: confidence,
            isReviewed: reviewed,
            isExpired: expiresAtMs.map { $0 <= nowMs } ?? false
        )
    }

    package static func rankingReasons(
        metadata: [String: String],
        scope: MemoryScopeContext?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
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
            adjustment += 0.20
            reasons.append("handoff")
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
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> (adjustment: Float, reasons: [String]) {
        guard let stats else { return (0, []) }
        var adjustment: Float = 0
        var reasons: [String] = []
        if stats.accessCount >= 3 {
            adjustment += min(0.25, Float(stats.accessCount) * 0.03)
            reasons.append("repeated use")
        }
        let hoursSinceAccess = max(0, nowMs - stats.lastAccessMs) / (1000 * 60 * 60)
        if hoursSinceAccess <= 24 {
            adjustment += 0.15
            reasons.append("recently used")
        }
        return (adjustment, reasons)
    }

    package static func classifyCandidate(text: String, metadata: [String: String]) -> MemoryType {
        if let raw = metadata[MemoryMetadataKeys.type],
           let typed = MemoryType(rawValue: raw),
           typed != .taskState {
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

    package static func normalizedTextFingerprint(_ text: String) -> String {
        let normalized = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized
    }

    package static func similarity(lhs: String, rhs: String) -> Float {
        let lhsTerms = Set(normalizedTextFingerprint(lhs).split(separator: " ").map(String.init))
        let rhsTerms = Set(normalizedTextFingerprint(rhs).split(separator: " ").map(String.init))
        guard !lhsTerms.isEmpty || !rhsTerms.isEmpty else { return 0 }
        let overlap = lhsTerms.intersection(rhsTerms).count
        let union = lhsTerms.union(rhsTerms).count
        guard union > 0 else { return 0 }
        return Float(overlap) / Float(union)
    }

    package static func defaultDurability(for type: MemoryType) -> MemoryDurability {
        switch type {
        case .taskState, .handoff:
            return .ephemeral
        case .note:
            return .working
        case .decision, .userPreference, .lesson, .constraint, .fact:
            return .durable
        }
    }

    private static func defaultMemoryType(sessionID: UUID?, existing metadata: [String: String]) -> MemoryType {
        if let raw = metadata[MemoryMetadataKeys.type], let typed = MemoryType(rawValue: raw) {
            return typed
        }
        if sessionID != nil || metadata["session_id"] != nil {
            return .taskState
        }
        return .note
    }

    private static func normalizedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func gitRepositoryRoot(startingAt url: URL) -> URL? {
        var current = url
        let fileManager = FileManager.default
        while true {
            let gitPath = current.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }
}
