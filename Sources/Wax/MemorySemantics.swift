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
    package var checkoutStatus: MemoryCheckoutStatus?

    package init(
        type: MemoryType? = nil,
        durability: MemoryDurability? = nil,
        project: String? = nil,
        repo: String? = nil,
        confidence: Float? = nil,
        expiresInDays: Int? = nil,
        reviewed: Bool = false,
        lock: Bool = false,
        checkoutStatus: MemoryCheckoutStatus? = nil
    ) {
        self.type = type
        self.durability = durability
        self.project = project
        self.repo = repo
        self.confidence = confidence
        self.expiresInDays = expiresInDays
        self.reviewed = reviewed
        self.lock = lock
        self.checkoutStatus = checkoutStatus
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
            reviewed: semantics.reviewed,
            checkoutStatus: semantics.checkoutStatus
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
        // Explicit ephemeral/working durability is a session intent: honor it
        // via session when a session exists instead of silently escalating
        // to durable. Without a session, reject with guidance.
        let typeSelectsSession = resolvedType == .note
            || resolvedType == .handoff
            || resolvedType == .taskState
        let requestsTransientDurability = requestedDurability == .ephemeral
            || requestedDurability == .working
        if let sessionID, writeScope == .session || typeSelectsSession || requestsTransientDurability {
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

        if requestsTransientDurability {
            throw BrokerValidationError.invalid(
                "durability \(requestedDurability?.rawValue ?? "ephemeral") requires scope session with an active session_id; pass scope session or omit durability to use the memory_type default"
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
                lock: false,
                checkoutStatus: fields.checkoutStatus
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
                lock: false,
                checkoutStatus: fields.checkoutStatus
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
    package var checkoutStatus: MemoryCheckoutStatus?

    package init(
        project: String? = nil,
        repo: String? = nil,
        confidence: Float? = nil,
        expiresInDays: Int? = nil,
        reviewed: Bool = false,
        checkoutStatus: MemoryCheckoutStatus? = nil
    ) {
        self.project = project
        self.repo = repo
        self.confidence = confidence
        self.expiresInDays = expiresInDays
        self.reviewed = reviewed
        self.checkoutStatus = checkoutStatus
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
            lock: durability == .locked,
            checkoutStatus: fields.checkoutStatus
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
    package static let gitSHA = "wax.git.sha"
    package static let gitBranch = "wax.git.branch"
    package static let gitWorktree = "wax.git.worktree"
    package static let checkoutStatus = "wax.checkout.status"
    package static let onThisTree = "wax.git.on_this_tree"
}

package enum MemoryCheckoutStatus: String, Sendable {
    case intent
    case landed
}

package enum OnThisTree: String, Sendable {
    case yes
    case ancestor
    case other
    case unknown
}

package struct GitCheckoutSnapshot: Sendable, Equatable {
    package var sha: String?
    package var branch: String?
    package var worktree: String?

    package init(sha: String? = nil, branch: String? = nil, worktree: String? = nil) {
        self.sha = sha
        self.branch = branch
        self.worktree = worktree
    }
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

        // Git honesty and checkout_status are server-stamped. Client metadata
        // must not keep a spoofed SHA or landed flag when the snapshot misses.
        normalized.removeValue(forKey: MemoryMetadataKeys.onThisTree)
        normalized.removeValue(forKey: MemoryMetadataKeys.gitSHA)
        normalized.removeValue(forKey: MemoryMetadataKeys.gitBranch)
        normalized.removeValue(forKey: MemoryMetadataKeys.gitWorktree)
        normalized.removeValue(forKey: MemoryMetadataKeys.checkoutStatus)
        if let checkoutStatus = semantics.checkoutStatus {
            normalized[MemoryMetadataKeys.checkoutStatus] = checkoutStatus.rawValue
        } else if resolvedType == .decision || resolvedType == .constraint {
            normalized[MemoryMetadataKeys.checkoutStatus] = MemoryCheckoutStatus.intent.rawValue
        }

        let git = snapshotGitCheckout(startingAt: inferredScope?.cwdPath ?? inferredScope?.repoRootPath)
        if let sha = git.sha {
            normalized[MemoryMetadataKeys.gitSHA] = sha
        }
        if let branch = git.branch {
            normalized[MemoryMetadataKeys.gitBranch] = branch
        }
        if let worktree = git.worktree {
            normalized[MemoryMetadataKeys.gitWorktree] = worktree
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
        termJaccard(terms(lhs), terms(rhs))
    }

    private static func terms(_ text: String) -> Set<String> {
        Set(normalizedTextFingerprint(text).split(separator: " ").map(String.init))
    }

    private static func termJaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Float {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let overlap = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Float(overlap) / Float(union)
    }

    /// Term and identifier sets for one text, computed once so a corpus scan
    /// does not re-normalize and re-run the identifier regexes per pair.
    package struct TextSignature: Sendable, Equatable {
        package let terms: Set<String>
        package let identifiers: Set<String>
        /// Terms minus identifier tokens and stopwords: what the text says
        /// about its identifiers rather than which identifiers it names.
        package let contentTerms: Set<String>
        /// Whether the text negates ("not", "never", "don't", ...). See `isNegated`.
        package let negated: Bool

        package init(_ text: String) {
            let tokens = MemorySemantics.normalizedTextFingerprint(text).split(separator: " ").map(String.init)
            let terms = Set(tokens)
            let identifiers = MemorySemantics.extractIdentifiers(text)
            let identifierTerms = Set(identifiers.flatMap { MemorySemantics.terms($0) })
            self.terms = terms
            self.identifiers = identifiers
            self.contentTerms = terms
                .subtracting(identifierTerms)
                .subtracting(MemorySemantics.nearTwinStopwords)
                .subtracting(MemorySemantics.negationTerms)
            self.negated = MemorySemantics.isNegated(tokens)
        }
    }

    /// Term Jaccard of two precomputed signatures.
    package static func similarity(_ lhs: TextSignature, _ rhs: TextSignature) -> Float {
        termJaccard(lhs.terms, rhs.terms)
    }

    /// Jaccard over content terms (identifiers, stopwords and negations removed).
    package static func contentSimilarity(_ lhs: TextSignature, _ rhs: TextSignature) -> Float {
        termJaccard(lhs.contentTerms, rhs.contentTerms)
    }

    package static func contentSimilarity(lhs: String, rhs: String) -> Float {
        contentSimilarity(TextSignature(lhs), TextSignature(rhs))
    }

    /// Function words dropped before the near-twin content comparison,
    /// so shared glue ("must be ... before the") cannot carry two different
    /// statements about the same identifiers over the floor.
    private static let nearTwinStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "by",
        "with", "from", "as", "into", "is", "are", "was", "were", "be", "been", "being",
        "it", "its", "this", "that", "these", "those", "them", "they", "we", "you", "i",
        "do", "does", "did", "must", "should", "will", "would", "can", "could", "may",
        "might", "shall", "than", "then", "so", "if", "when", "s", "t",
    ]

    /// Negation markers. Normalization splits "don't" into "don" + "t", so the
    /// contracted stems are listed rather than the apostrophe forms. "without"
    /// is left out: it qualifies ("without blocking") far more often than it negates.
    private static let negationTerms: Set<String> = [
        "not", "no", "never", "cannot",
        "don", "doesn", "didn", "isn", "aren", "wasn", "weren",
        "shouldn", "mustn", "couldn", "wouldn",
    ]

    /// True when a negation marker negates. Idioms that only look negative do
    /// not count: "no-op" (normalized "no op") and "not only".
    private static func isNegated(_ tokens: [String]) -> Bool {
        tokens.indices.contains { index in
            let token = tokens[index]
            guard negationTerms.contains(token) else { return false }
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token == "no", next == "op" { return false }
            if token == "not", next == "only" { return false }
            return true
        }
    }

    package static let identifierJaccardThreshold: Float = 0.5
    package static let identifierSharedCountThreshold = 3

    /// Content-term Jaccard floor for a near-twin, so a long newer text that
    /// happens to contain every word of a short memory does not swallow it.
    package static let nearTwinContentSimilarityFloor: Float = 0.5

    private static let pascalCaseRegex = makeRegex(#"[A-Z][a-z0-9]+(?:[A-Z][a-zA-Z0-9]+)+"#)
    private static let issueNumberRegex = makeRegex(#"#\d+"#)
    /// 7-40 hex chars with at least one letter and one digit: dates, plain
    /// numbers and hex-only words ("defaced") are not SHAs.
    private static let hexSHARegex = makeRegex(#"\b(?=[0-9a-fA-F]*[a-fA-F])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{7,40}\b"#)
    /// `PROJ-42` / `PR-145` style keys, or the repo's own `C01` (two or more
    /// digits) and `T1` IDs. Other letter+digit tokens (A1, L2, GPT4, ARM64,
    /// SHA256, MD5, X86, V2, S3, H264) name technologies, not tickets.
    private static let ticketIDRegex = makeRegex(#"\b(?:[A-Z]{2,10}-\d{1,6}|C\d{2,4}|T\d{1,4})\b"#)
    /// Prefixes of standards written like ticket keys (UTF-8, SHA-256, ISO-8601).
    private static let standardKeyPrefixes: Set<String> = [
        "utf", "ucs", "sha", "aes", "des", "iso", "iec", "ieee", "rsa", "hmac",
        "crc", "tls", "ssl", "http", "ipv", "md", "arm", "gpt", "x",
    ]

    /// PascalCase tokens, `#123`, 7+ hex SHAs, and `PROJ-42` / `C01` / `T1`-style IDs.
    package static func extractIdentifiers(_ text: String) -> Set<String> {
        identifiers(in: text, matching: [pascalCaseRegex, issueNumberRegex, hexSHARegex, ticketIDRegex])
    }

    private static func identifiers(in text: String, matching regexes: [NSRegularExpression]) -> Set<String> {
        var ids = Set<String>()
        for regex in regexes {
            var matches = regexMatches(regex, in: text)
            if regex === pascalCaseRegex {
                // A PascalCase identifier has lowercase letters; without this, the hex tail of a
                // token like "AC1F4B6A" also matched as "C1F4B6A" and one shared token counted twice.
                matches = matches.filter { $0.contains(where: \.isLowercase) }
            } else if regex === ticketIDRegex {
                matches = matches.filter { match in
                    guard let dash = match.firstIndex(of: "-") else { return true }
                    return !standardKeyPrefixes.contains(match[..<dash].lowercased())
                }
            }
            ids.formUnion(matches.map { $0.lowercased() })
        }
        return ids
    }

    package static func identifierOverlap(lhs: String, rhs: String) -> (jaccard: Float, shared: Int) {
        identifierOverlap(extractIdentifiers(lhs), extractIdentifiers(rhs))
    }

    package static func identifierOverlap(
        _ lhs: TextSignature,
        _ rhs: TextSignature
    ) -> (jaccard: Float, shared: Int) {
        identifierOverlap(lhs.identifiers, rhs.identifiers)
    }

    private static func identifierOverlap(
        _ left: Set<String>,
        _ right: Set<String>
    ) -> (jaccard: Float, shared: Int) {
        guard !left.isEmpty, !right.isEmpty else { return (0, 0) }
        let shared = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return (0, 0) }
        return (Float(shared) / Float(union), shared)
    }

    package static func identifiersMatch(_ lhs: String, _ rhs: String) -> Bool {
        identifiersMatch(overlap: identifierOverlap(lhs: lhs, rhs: rhs))
    }

    package static func identifiersMatch(_ lhs: TextSignature, _ rhs: TextSignature) -> Bool {
        identifiersMatch(overlap: identifierOverlap(lhs, rhs))
    }

    private static func identifiersMatch(overlap: (jaccard: Float, shared: Int)) -> Bool {
        if overlap.shared >= identifierSharedCountThreshold {
            return true
        }
        // A single shared SHA / PascalCase token is not a remaining-holes paraphrase.
        return overlap.shared >= 2 && overlap.jaccard >= identifierJaccardThreshold
    }

    /// Whether `newer` subsumes `older`, so `older` can be retired. Drives
    /// write-time auto-supersede (destructive), read-time stale-twin demotion,
    /// and `stale_hint` labels; callers pass the older and newer memory in order.
    /// True iff all of:
    /// 1. both agree on negation ("use X" vs "never use X"; "no-op", "not only"
    ///    and "without" do not count as negation);
    /// 2. every identifier `older` names (types, `#123`, SHAs, tickets) is also in `newer`;
    /// 3. every content term of `older` (lowercased terms minus identifier tokens,
    ///    stopwords and negations; numbers and units included) is also in `newer`:
    ///    `newer` may add words, never substitute or drop one;
    /// 4. content-term Jaccard >= `nearTwinContentSimilarityFloor` (0.5).
    /// A false negative only leaves a duplicate live; a false positive loses a
    /// fact, so anything short of subsumption stays live side by side. This is
    /// bag-of-words: it cannot tell role swaps apart ("A calls B" vs "B calls A").
    package static func isNearTwin(older: TextSignature, newer: TextSignature) -> Bool {
        older.negated == newer.negated
            && older.identifiers.isSubset(of: newer.identifiers)
            && older.contentTerms.isSubset(of: newer.contentTerms)
            && contentSimilarity(older, newer) >= nearTwinContentSimilarityFloor
    }

    package static func isNearTwin(older: String, newer: String) -> Bool {
        isNearTwin(older: TextSignature(older), newer: TextSignature(newer))
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("invalid built-in identifier regex \(pattern): \(error)")
        }
    }

    private static func regexMatches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
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

    /// Filesystem snapshot of the caller's checkout. Never invents a SHA.
    package static func snapshotGitCheckout(startingAt path: String?) -> GitCheckoutSnapshot {
        guard let path, let start = resolvedAbsoluteDirectoryPath(
            path,
            processDirectoryPath: ""
        ) ?? (path.hasPrefix("/") ? normalizeAbsolutePath(path) : nil) else {
            return GitCheckoutSnapshot()
        }
        guard let gitMarker = gitMarkerPath(startingAt: start) else {
            return GitCheckoutSnapshot()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitMarker, isDirectory: &isDirectory) else {
            return GitCheckoutSnapshot()
        }
        let gitDir: String
        let worktree: String?
        if isDirectory.boolValue {
            gitDir = gitMarker
            worktree = nil
        } else {
            guard let pointed = parseGitdirPointer(at: gitMarker) else {
                return GitCheckoutSnapshot()
            }
            gitDir = pointed
            let name = lastPathComponent(parentDirectoryPath(gitMarker) ?? "")
            worktree = (name.isEmpty || name == "/") ? nil : name
        }
        let (sha, branch) = readHead(gitDir: gitDir)
        return GitCheckoutSnapshot(sha: sha, branch: branch, worktree: worktree)
    }

    /// SHA compare only. Returns `.yes`, `.other`, or `.unknown`. Never `.ancestor`, and never starts a process.
    package static func classifyCheckout(
        storedSHA: String?,
        live: GitCheckoutSnapshot
    ) -> OnThisTree {
        guard let stored = normalizeGitSHA(storedSHA), let liveSHA = normalizeGitSHA(live.sha) else {
            return .unknown
        }
        if gitSHA(stored, matches: liveSHA) {
            return .yes
        }
        return .other
    }

    /// One relation per stored SHA. `git merge-base --is-ancestor` runs only for unequal SHAs when `repoRootPath` is set.
    package static func checkoutRelations(
        storedSHAs: some Sequence<String>,
        live: GitCheckoutSnapshot,
        repoRootPath: String?
    ) -> [String: OnThisTree] {
        var relations: [String: OnThisTree] = [:]
        let liveSHA = normalizeGitSHA(live.sha)
        for storedSHA in storedSHAs {
            if relations[storedSHA] != nil { continue }
            let classified = classifyCheckout(storedSHA: storedSHA, live: live)
            if classified == .other,
               let repoRootPath,
               let stored = normalizeGitSHA(storedSHA),
               let liveSHA,
               isGitAncestor(stored, of: liveSHA, repoRootPath: repoRootPath) {
                relations[storedSHA] = .ancestor
            } else {
                relations[storedSHA] = classified
            }
        }
        return relations
    }

    package static func onThisTree(
        storedSHA: String?,
        live: GitCheckoutSnapshot,
        repoRootPath: String? = nil
    ) -> OnThisTree {
        guard let storedSHA else { return .unknown }
        return checkoutRelations(
            storedSHAs: [storedSHA],
            live: live,
            repoRootPath: repoRootPath
        )[storedSHA] ?? .unknown
    }

    package static func looksLandedClaim(metadata: [String: String], text: String) -> Bool {
        if metadata[MemoryMetadataKeys.checkoutStatus] == MemoryCheckoutStatus.landed.rawValue {
            return true
        }
        let lowered = text.lowercased()
        return lowered.contains("strong execute") || lowered.contains("shipped on")
    }

    private static func gitMarkerPath(startingAt path: String) -> String? {
        var current = path
        let fileManager = FileManager.default
        for _ in 0..<256 {
            let gitPath = current == "/" ? "/.git" : "\(current)/.git"
            if fileManager.fileExists(atPath: gitPath) {
                return gitPath
            }
            guard let parent = parentDirectoryPath(current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func readHead(gitDir: String) -> (sha: String?, branch: String?) {
        let headPath = gitDir + "/HEAD"
        guard let raw = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return (nil, nil)
        }
        let line = raw.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if line.lowercased().hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count))
                : nil
            return (readRefSHA(gitDir: gitDir, ref: ref), branch)
        }
        return (normalizeGitSHA(line), nil)
    }

    private static func readRefSHA(gitDir: String, ref: String) -> String? {
        if let sha = readSHAFile(gitDir + "/" + ref) {
            return sha
        }
        let common = stripWorktreesSuffix(fromGitDir: gitDir)
        if common != gitDir, let sha = readSHAFile(common + "/" + ref) {
            return sha
        }
        if let sha = readPackedRef(gitDir: gitDir, ref: ref) {
            return sha
        }
        if common != gitDir {
            return readPackedRef(gitDir: common, ref: ref)
        }
        return nil
    }

    private static func readSHAFile(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let line = raw.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return normalizeGitSHA(line)
    }

    private static func readPackedRef(gitDir: String, ref: String) -> String? {
        guard let raw = try? String(contentsOfFile: gitDir + "/packed-refs", encoding: .utf8) else {
            return nil
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("^") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, String(parts[1]) == ref else { continue }
            return normalizeGitSHA(String(parts[0]))
        }
        return nil
    }

    private static func normalizeGitSHA(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 7, trimmed.count <= 64,
              trimmed.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return trimmed
    }

    private static func gitSHA(_ lhs: String, matches rhs: String) -> Bool {
        if lhs == rhs { return true }
        let prefix = min(lhs.count, rhs.count)
        guard prefix >= 7 else { return false }
        return lhs.prefix(prefix) == rhs.prefix(prefix)
    }

    private static func isGitAncestor(_ stored: String, of live: String, repoRootPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRootPath, "merge-base", "--is-ancestor", stored, live]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
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
