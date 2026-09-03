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

/// Closed session vs durable remember write after wire decode.
package enum RememberDestination: Sendable, Equatable {
    case session(sessionID: UUID, write: SessionRememberWrite)
    case durable(write: DurableRememberWrite)

    package var sessionID: UUID? {
        switch self {
        case .session(let sessionID, _):
            return sessionID
        case .durable:
            return nil
        }
    }

    package var writeSemantics: MemoryWriteSemantics {
        switch self {
        case .session(_, let write):
            return write.writeSemantics
        case .durable(let write):
            return write.writeSemantics
        }
    }

    /// Maps MCP remember fields into a destination that cannot name illegal combos.
    package static func decode(
        sessionID: UUID?,
        writeScope: RememberWriteScope?,
        semantics: MemoryWriteSemantics,
        metadata: [String: String]
    ) throws -> RememberDestination {
        let metadataType = metadata[MemoryMetadataKeys.type].flatMap(MemoryType.init(rawValue:))
        let resolvedType = semantics.type ?? metadataType ?? .note
        let metadataDurability = metadata[MemoryMetadataKeys.durability]
            .flatMap(MemoryDurability.init(rawValue:))
        let requestedDurability = semantics.lock
            ? MemoryDurability.locked
            : semantics.durability ?? metadataDurability
        let fields = RememberWriteFields(
            project: semantics.project,
            repo: semantics.repo,
            confidence: semantics.confidence,
            expiresInDays: semantics.expiresInDays,
            reviewed: semantics.reviewed
        )

        if resolvedType == .taskState {
            if writeScope == .durable {
                throw BrokerValidationError.invalid(
                    "task_state cannot use scope durable; use scope session with an active session_id"
                )
            }
            guard let sessionID else {
                throw BrokerValidationError.invalid(
                    "task_state requires an active session_id; durable task diaries are not supported"
                )
            }
            if semantics.lock
                || requestedDurability == .durable
                || requestedDurability == .locked
                || metadataDurability == .durable
                || metadataDurability == .locked {
                throw BrokerValidationError.invalid(
                    "task_state cannot use durability durable or locked; use working session memory"
                )
            }
            return .session(sessionID: sessionID, write: .taskState(fields: fields))
        }

        if writeScope == .durable, sessionID != nil {
            throw BrokerValidationError.invalid("scope durable forbids session_id")
        }
        if writeScope == .session, sessionID == nil {
            throw BrokerValidationError.invalid("scope session requires session_id")
        }

        // Type selects horizon. session_id does not hijack durable types;
        // explicit scope=session still forces a session write where legal.
        let typeSelectsSession = resolvedType == .note
            || resolvedType == .handoff
            || resolvedType == .taskState
        if let sessionID, writeScope == .session || typeSelectsSession {
            let sessionDurability: SessionRememberDurability
            switch requestedDurability {
            case .durable, .locked:
                throw BrokerValidationError.invalid(
                    "session writes cannot use durability durable or locked; use working session memory"
                )
            case .ephemeral:
                sessionDurability = .ephemeral
            case .working, .none:
                sessionDurability = .working
            }
            let sessionType = try SessionRememberType(memoryType: resolvedType)
            return .session(
                sessionID: sessionID,
                write: .typed(type: sessionType, durability: sessionDurability, fields: fields)
            )
        }

        let durableType = try DurableRememberType(memoryType: resolvedType)
        let durableDurability: DurableRememberDurability
        if semantics.lock || requestedDurability == .locked {
            durableDurability = .locked
        } else if requestedDurability == .durable {
            durableDurability = .durable
        } else if requestedDurability == nil {
            switch MemorySemantics.defaultDurability(for: resolvedType) {
            case .locked:
                durableDurability = .locked
            case .durable, .working, .ephemeral:
                durableDurability = .durable
            }
        } else {
            durableDurability = .durable
        }
        return .durable(
            write: DurableRememberWrite(type: durableType, durability: durableDurability, fields: fields)
        )
    }
}

package enum RememberWriteScope: String, Sendable, Equatable {
    case session
    case durable
}

package enum SessionRememberWrite: Sendable, Equatable {
    /// Session-local working state; durability is always `working`.
    case taskState(fields: RememberWriteFields)
    case typed(type: SessionRememberType, durability: SessionRememberDurability, fields: RememberWriteFields)

    package var writeSemantics: MemoryWriteSemantics {
        switch self {
        case .taskState(let fields):
            return MemoryWriteSemantics(
                type: .taskState,
                durability: .working,
                project: fields.project,
                repo: fields.repo,
                confidence: fields.confidence,
                expiresInDays: fields.expiresInDays,
                reviewed: fields.reviewed,
                lock: false
            )
        case .typed(let type, let durability, let fields):
            return MemoryWriteSemantics(
                type: type.memoryType,
                durability: durability.memoryDurability,
                project: fields.project,
                repo: fields.repo,
                confidence: fields.confidence,
                expiresInDays: fields.expiresInDays,
                reviewed: fields.reviewed,
                lock: false
            )
        }
    }
}

package enum SessionRememberType: Sendable, Equatable {
    case note
    case userPreference
    case decision
    case lesson
    case handoff
    case constraint
    case fact

    package var memoryType: MemoryType {
        switch self {
        case .note: return .note
        case .userPreference: return .userPreference
        case .decision: return .decision
        case .lesson: return .lesson
        case .handoff: return .handoff
        case .constraint: return .constraint
        case .fact: return .fact
        }
    }

    package init(memoryType: MemoryType) throws {
        switch memoryType {
        case .taskState:
            throw BrokerValidationError.invalid(
                "task_state cannot be a typed session write; use SessionRememberWrite.taskState"
            )
        case .note: self = .note
        case .userPreference: self = .userPreference
        case .decision: self = .decision
        case .lesson: self = .lesson
        case .handoff: self = .handoff
        case .constraint: self = .constraint
        case .fact: self = .fact
        }
    }
}

package enum SessionRememberDurability: Sendable, Equatable {
    case ephemeral
    case working

    package var memoryDurability: MemoryDurability {
        switch self {
        case .ephemeral: return .ephemeral
        case .working: return .working
        }
    }
}

package enum DurableRememberType: Sendable, Equatable {
    case note
    case userPreference
    case decision
    case lesson
    case handoff
    case constraint
    case fact

    package var memoryType: MemoryType {
        switch self {
        case .note: return .note
        case .userPreference: return .userPreference
        case .decision: return .decision
        case .lesson: return .lesson
        case .handoff: return .handoff
        case .constraint: return .constraint
        case .fact: return .fact
        }
    }

    package init(memoryType: MemoryType) throws {
        switch memoryType {
        case .taskState:
            throw BrokerValidationError.invalid(
                "task_state requires an active session_id; durable task diaries are not supported"
            )
        case .note: self = .note
        case .userPreference: self = .userPreference
        case .decision: self = .decision
        case .lesson: self = .lesson
        case .handoff: self = .handoff
        case .constraint: self = .constraint
        case .fact: self = .fact
        }
    }
}

package enum DurableRememberDurability: Sendable, Equatable {
    case durable
    case locked

    package var memoryDurability: MemoryDurability {
        switch self {
        case .durable: return .durable
        case .locked: return .locked
        }
    }
}

package struct RememberWriteFields: Sendable, Equatable {
    package var project: String?
    package var repo: String?
    package var confidence: Float?
    package var expiresInDays: Int?
    package var reviewed: Bool

    package init(
        project: String? = nil,
        repo: String? = nil,
        confidence: Float? = nil,
        expiresInDays: Int? = nil,
        reviewed: Bool = false
    ) {
        self.project = project
        self.repo = repo
        self.confidence = confidence
        self.expiresInDays = expiresInDays
        self.reviewed = reviewed
    }
}

package struct DurableRememberWrite: Sendable, Equatable {
    package var type: DurableRememberType
    package var durability: DurableRememberDurability
    package var fields: RememberWriteFields

    package var writeSemantics: MemoryWriteSemantics {
        MemoryWriteSemantics(
            type: type.memoryType,
            durability: durability.memoryDurability,
            project: fields.project,
            repo: fields.repo,
            confidence: fields.confidence,
            expiresInDays: fields.expiresInDays,
            reviewed: fields.reviewed,
            lock: durability == .locked
        )
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
    package static let tier = "wax.tier"
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
    // Copy-first migration provenance. These keys are intentionally namespaced so
    // a repaired store can be audited without changing source frame identities.
    package static let migrationSchema = "wax.migration.schema"
    package static let migrationAction = "wax.migration.action"
    package static let migrationSourceFrameID = "wax.migration.source_frame_id"
    package static let migrationSourceContentHash = "wax.migration.source_content_hash"
    package static let migrationSourceStoreHash = "wax.migration.source_store_hash"
    package static let migrationOriginalSessionID = "wax.migration.original_session_id"
    package static let migrationOriginalMemoryType = "wax.migration.original_memory_type"
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
    package static func inferScopeContext(
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        processDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> MemoryScopeContext {
        guard let startPath = resolvedAbsoluteDirectoryPath(
            currentDirectoryPath,
            processDirectoryPath: processDirectoryPath
        ) else {
            let trimmed = currentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return MemoryScopeContext(cwdPath: trimmed.isEmpty ? nil : trimmed)
        }
        guard let repoRoot = gitRepositoryRoot(startingAt: startPath) else {
            return MemoryScopeContext(cwdPath: startPath)
        }
        let repoName = lastPathComponent(repoRoot)
        return MemoryScopeContext(
            cwdPath: startPath,
            repoRootPath: repoRoot,
            repoName: repoName,
            projectName: repoName
        )
    }

    package static func normalizeWriteMetadata(
        metadata: [String: String],
        semantics: MemoryWriteSemantics,
        sessionID: UUID?,
        inferredScope: MemoryScopeContext?,
        nowMs: Int64
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

        let explicitProject = normalizedOrNil(semantics.project)
            ?? normalizedOrNil(normalized[MemoryMetadataKeys.project])
        let explicitRepo = normalizedOrNil(semantics.repo)
            ?? normalizedOrNil(normalized[MemoryMetadataKeys.repo])
        if let project = explicitProject ?? normalizedOrNil(inferredScope?.projectName) {
            normalized[MemoryMetadataKeys.project] = project
        }
        if let repo = explicitRepo ?? explicitProject ?? normalizedOrNil(inferredScope?.repoName) {
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

    /// Validates a closed remember destination and returns normalized metadata.
    package static func validatedWriteMetadata(
        metadata: [String: String],
        destination: RememberDestination,
        activeSession: Bool,
        inferredScope: MemoryScopeContext?,
        nowMs: Int64
    ) throws -> [String: String] {
        let scope: String
        switch destination {
        case .session:
            scope = "session"
        case .durable:
            scope = "durable"
        }
        return try validatedWriteMetadata(
            metadata: metadata,
            semantics: destination.writeSemantics,
            sessionID: destination.sessionID,
            scope: scope,
            activeSession: activeSession,
            inferredScope: inferredScope,
            nowMs: nowMs
        )
    }

    /// Validates the broker write contract and returns normalized metadata.
    ///
    /// `task_state` is session-local state. It must never be written without a
    /// live virtual session and it cannot be promoted into the durable horizon.
    /// A session task-state write is always represented as `working`; an omitted
    /// or legacy `ephemeral` durability is upgraded, while an explicit durable
    /// or locked request is rejected so callers cannot silently lose intent.
    package static func validatedWriteMetadata(
        metadata: [String: String],
        semantics: MemoryWriteSemantics,
        sessionID: UUID?,
        scope: String?,
        activeSession: Bool,
        inferredScope: MemoryScopeContext?,
        nowMs: Int64
    ) throws -> [String: String] {
        let metadataType = metadata[MemoryMetadataKeys.type].flatMap(MemoryType.init(rawValue:))
        let resolvedType = semantics.type ?? metadataType ?? defaultMemoryType(
            sessionID: sessionID,
            existing: metadata
        )
        let metadataDurability = metadata[MemoryMetadataKeys.durability]
            .flatMap(MemoryDurability.init(rawValue:))
        let requestedDurability = semantics.lock
            ? MemoryDurability.locked
            : semantics.durability ?? metadataDurability

        guard resolvedType == .taskState else {
            return normalizeWriteMetadata(
                metadata: metadata,
                semantics: semantics,
                sessionID: sessionID,
                inferredScope: inferredScope,
                nowMs: nowMs
            )
        }

        guard activeSession, let sessionID else {
            throw BrokerValidationError.invalid(
                "task_state requires an active session_id; durable task diaries are not supported"
            )
        }
        if scope?.lowercased() == "durable" {
            throw BrokerValidationError.invalid(
                "task_state cannot use scope durable; use scope session with an active session_id"
            )
        }
        if semantics.lock ||
            requestedDurability == .durable ||
            requestedDurability == .locked ||
            metadataDurability == .durable ||
            metadataDurability == .locked {
            throw BrokerValidationError.invalid(
                "task_state cannot use durability durable or locked; use working session memory"
            )
        }

        var sessionSemantics = semantics
        sessionSemantics.type = .taskState
        sessionSemantics.durability = .working
        sessionSemantics.lock = false
        return normalizeWriteMetadata(
            metadata: metadata,
            semantics: sessionSemantics,
            sessionID: sessionID,
            inferredScope: inferredScope,
            nowMs: nowMs
        )
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

    package static func parse(metadata: [String: String], nowMs: Int64) -> MemorySemanticInfo {
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

    private static func defaultMemoryType(sessionID _: UUID?, existing metadata: [String: String]) -> MemoryType {
        if let raw = metadata[MemoryMetadataKeys.type], let typed = MemoryType(rawValue: raw) {
            return typed
        }
        // Session presence does not imply task_state. Ordinary session notes stay
        // notes so the task_state safety contract applies only when requested.
        return .note
    }

    private static func normalizedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Walks `path` by dropping string components. Never uses `URL.deletingLastPathComponent`,
    /// which turns empty/`.`/`./` into `../` forever when cwd is missing.
    ///
    /// Linked worktrees (`.git` file with `gitdir: …/worktrees/<name>`) resolve to the
    /// main repository directory name, not the worktree folder basename.
    package static func gitRepositoryRoot(startingAt path: String) -> String? {
        var current = path
        let fileManager = FileManager.default
        for _ in 0..<256 {
            let gitPath = current == "/" ? "/.git" : "\(current)/.git"
            if fileManager.fileExists(atPath: gitPath) {
                return resolveRepositoryRoot(fromGitMarkerAt: gitPath)
            }
            guard let parent = parentDirectoryPath(current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Resolves the main repository root from a `.git` directory or gitdir file.
    package static func resolveRepositoryRoot(fromGitMarkerAt gitPath: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return parentDirectoryPath(gitPath)
        }
        guard let gitDir = parseGitdirPointer(at: gitPath) else {
            return nil
        }
        let commonGitDir = stripWorktreesSuffix(fromGitDir: gitDir)
        return parentDirectoryPath(commonGitDir)
    }

    /// Reads `gitdir: <path>` from a `.git` file (linked worktree). Relative paths
    /// resolve against the directory containing the `.git` file.
    package static func parseGitdirPointer(at gitFilePath: String) -> String? {
        guard let raw = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
            return nil
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 7, trimmed.prefix(7).lowercased() == "gitdir:" else {
                continue
            }
            let value = trimmed.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.hasPrefix("/") {
                return normalizeAbsolutePath(value)
            }
            guard let parent = parentDirectoryPath(gitFilePath) else { return nil }
            return normalizeAbsolutePath(parent + "/" + value)
        }
        return nil
    }

    /// `/repo/.git/worktrees/<name>` → `/repo/.git`; otherwise returns `gitDir` unchanged.
    package static func stripWorktreesSuffix(fromGitDir gitDir: String) -> String {
        let marker = "/worktrees/"
        guard let range = gitDir.range(of: marker) else {
            return gitDir
        }
        return String(gitDir[..<range.lowerBound])
    }

    private static func resolvedAbsoluteDirectoryPath(
        _ path: String,
        processDirectoryPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if trimmed.hasPrefix("/") {
            return normalizeAbsolutePath(trimmed)
        }
        let cwd = processDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cwd.hasPrefix("/") else {
            return nil
        }
        if trimmed == "." || trimmed == "./" {
            return normalizeAbsolutePath(cwd)
        }
        return normalizeAbsolutePath(cwd + "/" + trimmed)
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/")
    }

    private static func parentDirectoryPath(_ path: String) -> String? {
        if path.isEmpty || path == "." || path == "./" {
            return nil
        }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed == "/" {
            return nil
        }
        guard let slash = trimmed.lastIndex(of: "/") else {
            return nil
        }
        if slash == trimmed.startIndex {
            return "/"
        }
        return String(trimmed[..<slash])
    }

    private static func lastPathComponent(_ path: String) -> String {
        if path == "/" { return "/" }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let slash = trimmed.lastIndex(of: "/") else {
            return trimmed
        }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
