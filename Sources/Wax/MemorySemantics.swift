import Foundation

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
        // Promotion and sync carry an earlier creation time on purpose; keep it
        // only when it parses as a positive epoch-ms value.
        let suppliedCreatedAtMs: Int64? = normalized[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init)
        if (suppliedCreatedAtMs ?? 0) <= 0 {
            normalized[MemoryMetadataKeys.createdAtMs] = String(nowMs)
        }

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
}
