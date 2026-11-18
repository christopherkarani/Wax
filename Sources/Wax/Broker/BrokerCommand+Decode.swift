import Foundation
import WaxCore

// MARK: - Payload decode

extension BrokerCommand.Remember {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let content = try args.requiredStringPreservingWhitespace(
            "content",
            maxBytes: BrokerLimits.maxContentBytes
        )
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BrokerValidationError.invalid("content must not be empty")
        }
        let sessionID = try BrokerCommand.parseOptionalSessionID(args)
        let writeScope = try BrokerCommand.parseRememberWriteScope(args)
        if let writeScope {
            switch writeScope {
            case .session:
                guard sessionID != nil else {
                    throw BrokerValidationError.invalid("scope session requires session_id")
                }
            case .durable:
                if sessionID != nil {
                    throw BrokerValidationError.invalid("scope durable forbids session_id")
                }
            }
        }
        let rawMetadata = try BrokerCommand.coerceMetadata(try args.optionalObject("metadata"))
        if rawMetadata["session_id"] != nil {
            throw BrokerValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        let writeSemantics = try BrokerCommand.parseWriteSemantics(args)
        let destination = try RememberDestination.decode(
            sessionID: sessionID,
            writeScope: writeScope,
            semantics: writeSemantics,
            metadata: rawMetadata
        )
        return Self(
            content: content,
            destination: destination,
            metadata: rawMetadata,
            cwd: try args.optionalString("cwd"),
            clientSessionID: sessionID
        )
    }
}

extension BrokerCommand.Recall {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let query = try BrokerCommand.requireNonEmptyQuery(args)
        let limit = try args.optionalInt("limit") ?? 5
        guard (1...BrokerLimits.maxRecallLimit).contains(limit) else {
            throw BrokerValidationError.invalid(
                "limit must be between 1 and \(BrokerLimits.maxRecallLimit)"
            )
        }
        let scope = try BrokerCommand.parseRecallScope(args)
        let filters = try BrokerCommand.parseSearchFilters(args)
        let identity = try RecallIdentity.make(scope: scope, sessionID: filters.sessionId)
        let mode = try BrokerCommand.parseRecallMode(args)
        let searchTopKRaw = try args.optionalInt("search_top_k")
        let topKAliasRaw = try args.optionalInt("topK")
        if let searchTopKRaw, let topKAliasRaw, searchTopKRaw != topKAliasRaw {
            throw BrokerValidationError.invalid(
                "search_top_k and topK alias conflict (\(searchTopKRaw) vs \(topKAliasRaw)); pass only search_top_k"
            )
        }
        let requestedTopK = searchTopKRaw ?? topKAliasRaw
        if let requestedTopK, !(1...BrokerLimits.maxTopK).contains(requestedTopK) {
            throw BrokerValidationError.invalid(
                "search_top_k must be between 1 and \(BrokerLimits.maxTopK)"
            )
        }
        // search_top_k is the retrieval-stage width; limit is the final
        // assembly cap. A narrower retrieval than the requested limit would
        // under-fill by construction, so floor retrieval at limit. The lane
        // still inflates via retrievalTopK for project hard-filter headroom.
        let searchTopK = max(requestedTopK ?? limit, limit)
        return Self(
            query: query,
            limit: limit,
            searchTopK: searchTopK,
            identity: identity,
            mode: mode,
            filters: filters,
            explicitProject: try args.optionalString("project"),
            explicitRepo: try args.optionalString("repo"),
            clientCWD: try args.optionalString("cwd"),
            verbosity: try BrokerCommand.parseResponseVerbosity(args),
            memoryTypes: try BrokerCommand.parseMemoryTypes(args),
            includeWorking: try args.optionalBool("include_working") ?? false
        )
    }
}

extension BrokerCommand.Search {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let query = try BrokerCommand.requireNonEmptyQuery(args)
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try BrokerCommand.parseSearchMode(
            modeRaw: modeRaw,
            alpha: try args.optionalDouble("alpha")
        )
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...BrokerLimits.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(BrokerLimits.maxTopK)")
        }
        return Self(
            query: query,
            mode: mode,
            topK: topK,
            filters: try BrokerCommand.parseSearchFilters(args)
        )
    }
}

extension BrokerCommand.MemorySearch {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let query = try BrokerCommand.requireNonEmptyQuery(args)
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...BrokerLimits.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(BrokerLimits.maxTopK)")
        }
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try BrokerCommand.parseSearchMode(
            modeRaw: modeRaw,
            alpha: try args.optionalDouble("alpha")
        )
        var horizons = HorizonSet()
        if try args.optionalBool("include_working") ?? true {
            horizons.insert(.working)
        }
        if try args.optionalBool("include_episodic") ?? true {
            horizons.insert(.episodic)
        }
        if try args.optionalBool("include_durable") ?? true {
            horizons.insert(.durable)
        }
        guard !horizons.isEmpty else {
            throw BrokerValidationError.invalid(
                "at least one horizon lane must stay enabled; include_working, include_episodic and include_durable are all false"
            )
        }
        return Self(
            query: query,
            mode: mode,
            topK: topK,
            clientSessionID: try BrokerCommand.parseOptionalSessionID(args),
            requestedHorizons: horizons
        )
    }
}

extension BrokerCommand.SessionStart {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            agentID: try args.optionalString("agent_id"),
            runID: try args.optionalString("run_id"),
            cwd: try args.optionalString("cwd"),
            project: BrokerCommand.normalizedOrNil(try args.optionalString("project")),
            repo: BrokerCommand.normalizedOrNil(try args.optionalString("repo")),
            conversationID: BrokerCommand.normalizedOrNil(try args.optionalString("conversation_id"))
        )
    }
}

extension BrokerCommand.SessionResume {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            agentID: try args.optionalString("agent_id"),
            runID: try args.optionalString("run_id")
        )
    }
}

extension BrokerCommand.SessionEnd {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(sessionID: try BrokerCommand.parseOptionalSessionID(args))
    }
}

extension BrokerCommand.Handoff {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            content: try args.requiredStringPreservingWhitespace(
                "content",
                maxBytes: BrokerLimits.maxContentBytes
            ),
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            project: try args.optionalString("project"),
            pendingTasks: try args.optionalStringArray("pending_tasks") ?? []
        )
    }
}

extension BrokerCommand.HandoffLatest {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(project: try args.optionalString("project"))
    }
}

extension BrokerCommand.MemoryGet {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let raw = try args.requiredString("memory_id", maxBytes: BrokerLimits.maxMemoryIDBytes)
        return Self(memoryID: try MemoryID.parse(raw))
    }
}

extension BrokerCommand.Stats {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(sessionID: try BrokerCommand.parseOptionalSessionID(args))
    }
}

extension BrokerCommand.MemoryMaintain {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let apply = try args.optionalBool("apply") ?? false
        let dryRun = try args.optionalBool("dry_run")
        return Self(
            apply: dryRun == true ? false : apply,
            forceReclaim: try args.optionalBool("force_reclaim") ?? false
        )
    }
}

extension BrokerCommand.MarkdownSync {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            rootDir: try args.requiredString("root_dir", maxBytes: BrokerLimits.maxPathBytes),
            dryRun: try args.optionalBool("dry_run") ?? false
        )
    }
}

extension BrokerCommand.EntityUpsert {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            key: EntityKey(try args.requiredString("key", maxBytes: BrokerLimits.maxGraphIdentifierBytes)),
            kind: try args.requiredString("kind", maxBytes: BrokerLimits.maxGraphKindBytes),
            aliases: try args.optionalStringArray("aliases") ?? []
        )
    }
}

extension BrokerCommand.EntityResolve {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let limit = try args.optionalInt("limit") ?? 10
        guard (1...BrokerLimits.maxEntityResolveLimit).contains(limit) else {
            throw BrokerValidationError.invalid(
                "limit must be between 1 and \(BrokerLimits.maxEntityResolveLimit)"
            )
        }
        return Self(
            alias: try args.requiredString("alias", maxBytes: BrokerLimits.maxGraphIdentifierBytes),
            limit: limit
        )
    }
}

extension BrokerCommand.FactRetract {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            factID: FactRowID(rawValue: try args.requiredInt64("fact_id")),
            atMs: try args.optionalInt64("at_ms")
        )
    }
}

extension BrokerCommand.SessionSynthesize {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let maxCandidates = try args.optionalInt("max_candidates").map {
            min(max(1, $0), BrokerPromotionSettings.maxCandidateLimit)
        }
        return Self(
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            minimumConfidence: try BrokerCommand.parseMinimumConfidence(args),
            minimumRecallCount: try BrokerCommand.parseMinimumRecallCount(args),
            maxCandidates: maxCandidates
        )
    }
}

extension BrokerCommand.KnowledgeCapture {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let sessionID = try BrokerCommand.parseOptionalSessionID(args)
        let writeScope = try BrokerCommand.parseRememberWriteScope(args)
        if let writeScope {
            switch writeScope {
            case .session:
                guard sessionID != nil else {
                    throw BrokerValidationError.invalid("scope session requires session_id")
                }
            case .durable:
                if sessionID != nil {
                    throw BrokerValidationError.invalid("scope durable forbids session_id")
                }
            }
        }
        var writeSemantics = try BrokerCommand.parseWriteSemantics(args)
        if !writeSemantics.lock, writeSemantics.durability == nil, sessionID == nil {
            writeSemantics.durability = .durable
        }
        let metadata = try BrokerCommand.coerceMetadata(try args.optionalObject("metadata"))
        if metadata["session_id"] != nil {
            throw BrokerValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        let destination = try RememberDestination.decode(
            sessionID: sessionID,
            writeScope: writeScope,
            semantics: writeSemantics,
            metadata: metadata
        )
        return Self(
            content: try args.requiredStringPreservingWhitespace(
                "content",
                maxBytes: BrokerLimits.maxContentBytes
            ),
            destination: destination,
            metadata: metadata,
            cwd: try args.optionalString("cwd"),
            graphWrite: try KnowledgeGraphWrite.decode(args)
        )
    }
}

extension BrokerCommand.SessionClose {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            content: try args.requiredStringPreservingWhitespace(
                "content",
                maxBytes: BrokerLimits.maxContentBytes
            ),
            project: try args.optionalString("project"),
            pendingTasks: try args.optionalStringArray("pending_tasks") ?? [],
            recordHandoff: try args.optionalBool("record_handoff") ?? true
        )
    }
}

extension BrokerCommand.SessionOpen {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            project: BrokerCommand.normalizedOrNil(try args.optionalString("project")),
            repo: BrokerCommand.normalizedOrNil(try args.optionalString("repo")),
            agentID: try args.optionalString("agent_id"),
            runID: try args.optionalString("run_id"),
            recallQuery: try args.optionalString("recall_query"),
            cwd: try args.optionalString("cwd"),
            conversationID: BrokerCommand.normalizedOrNil(try args.optionalString("conversation_id")),
            sessionID: try BrokerCommand.parseOptionalSessionID(args)
        )
    }
}

extension BrokerCommand.CompactContext {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let tokenBudget = try args.optionalInt("token_budget") ?? 1800
        guard (128...BrokerLimits.maxCompactContextTokenBudget).contains(tokenBudget) else {
            throw BrokerValidationError.invalid(
                "token_budget must be between 128 and \(BrokerLimits.maxCompactContextTokenBudget)"
            )
        }
        let maxItems = try args.optionalInt("max_items") ?? 12
        guard (1...BrokerLimits.maxCompactContextItems).contains(maxItems) else {
            throw BrokerValidationError.invalid(
                "max_items must be between 1 and \(BrokerLimits.maxCompactContextItems)"
            )
        }
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try BrokerCommand.parseSearchMode(
            modeRaw: modeRaw,
            alpha: try args.optionalDouble("alpha")
        )
        return Self(
            query: try BrokerCommand.requireNonEmptyQuery(args),
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            tokenBudget: tokenBudget,
            maxItems: maxItems,
            mode: mode
        )
    }
}

extension BrokerCommand.MarkdownExport {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            outputDir: try args.requiredString("output_dir", maxBytes: BrokerLimits.maxPathBytes),
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            project: try args.optionalString("project"),
            allProjects: try args.optionalBool("all_projects") ?? false,
            cwd: try args.optionalString("cwd")
        )
    }
}

extension BrokerCommand.TaskStateMigrate {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let rawPolicy = try args.optionalString("orphan_policy") ?? TaskStateOrphanPolicy.quarantine.rawValue
        guard let orphanPolicy = TaskStateOrphanPolicy(rawValue: rawPolicy.lowercased()) else {
            throw BrokerValidationError.invalid(
                "orphan_policy must be one of: \(TaskStateOrphanPolicy.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return Self(
            destinationPath: try args.requiredString("destination_path", maxBytes: BrokerLimits.maxPathBytes),
            dryRun: try args.optionalBool("dry_run") ?? false,
            orphanPolicy: orphanPolicy,
            overwriteDestination: try args.optionalBool("overwrite_destination") ?? false
        )
    }
}

extension BrokerCommand.FactsQuery {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let limit = try args.optionalInt("limit") ?? 20
        guard (1...BrokerLimits.maxGraphLimit).contains(limit) else {
            throw BrokerValidationError.invalid("limit must be between 1 and \(BrokerLimits.maxGraphLimit)")
        }
        return Self(
            subject: try args.optionalString("subject").map { EntityKey($0) },
            predicate: try args.optionalString("predicate").map { PredicateKey($0) },
            asOfMs: try args.optionalInt64("as_of"),
            systemAsOfMs: try args.optionalInt64("system_as_of"),
            validAsOfMs: try args.optionalInt64("valid_as_of"),
            limit: limit
        )
    }
}

extension BrokerCommand.MemoryPromote {
    package static func decode(_ args: BrokerArguments, defaultApprove: Bool) throws -> Self {
        let maxCandidates = try args.optionalInt("max_candidates").map {
            min(max(1, $0), BrokerPromotionSettings.maxCandidateLimit)
        }
        return Self(
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            approve: try args.optionalBool("approve") ?? defaultApprove,
            frameID: try args.optionalUInt64("frame_id"),
            content: try args.optionalStringPreservingWhitespace("content"),
            metadata: try BrokerCommand.coerceMetadata(try args.optionalObject("metadata")),
            writeSemantics: try BrokerCommand.parseWriteSemantics(args),
            cwd: try args.optionalString("cwd"),
            minimumConfidence: try BrokerCommand.parseMinimumConfidence(args),
            minimumRecallCount: try BrokerCommand.parseMinimumRecallCount(args),
            maxCandidates: maxCandidates
        )
    }
}

extension BrokerCommand.FactAssert {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            subject: EntityKey(try args.requiredString("subject", maxBytes: BrokerLimits.maxGraphIdentifierBytes)),
            predicate: PredicateKey(try args.requiredString("predicate", maxBytes: BrokerLimits.maxGraphIdentifierBytes)),
            object: try BrokerCommand.parseFactValue(try args.requiredValue("object")),
            relation: try args.optionalString("relation").map { try BrokerCommand.parseVersionRelation($0) } ?? .sets,
            validFromMs: try args.optionalInt64("valid_from"),
            validToMs: try args.optionalInt64("valid_to"),
            evidence: try BrokerCommand.parseStructuredEvidence(try args.optionalValue("evidence"))
        )
    }
}

extension BrokerCommand.CorpusSearch {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...BrokerLimits.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(BrokerLimits.maxTopK)")
        }
        let modeRaw = try args.optionalString("mode")?.lowercased()
        return Self(
            query: try BrokerCommand.requireNonEmptyQuery(args),
            recursive: try args.optionalBool("recursive") ?? true,
            rebuild: try args.optionalBool("rebuild") ?? BrokerCommandCatalog.corpusSearchDefaultRebuild,
            mode: try BrokerCommand.parseSearchMode(
                modeRaw: modeRaw,
                alpha: try args.optionalDouble("alpha")
            ),
            topK: topK,
            expand: try args.optionalBool("expand") ?? false,
            sessionID: try BrokerCommand.parseOptionalSessionID(args)
        )
    }
}
