import Foundation

/// Typed broker command decoded from the wire (`command` + `arguments`).
///
/// Migrated tools decode to associated payloads. Remaining commands decode as
/// ``passthrough`` after surface allowlist validation so handlers can migrate
/// incrementally without changing JSON wire shape.
package enum BrokerCommand: Sendable, Equatable {
    case remember(Remember)
    case memoryAppend(Remember)
    case recall(Recall)
    case search(Search)
    case memorySearch(MemorySearch)
    case sessionStart(SessionStart)
    case sessionResume(SessionResume)
    case sessionEnd(SessionEnd)
    case handoff(Handoff)
    case handoffLatest(HandoffLatest)
    case memoryGet(MemoryGet)
    case memoryHealth
    case stats(Stats)
    case flush
    case markdownSync(MarkdownSync)
    case entityUpsert(EntityUpsert)
    case entityResolve(EntityResolve)
    case factRetract(FactRetract)
    /// `shutdown` / `exit` / `quit` — same handler, exits the broker process.
    case shutdown
    /// Known command not yet migrated to a typed payload.
    case passthrough(command: String, arguments: [String: AgentBrokerValue])

    package enum RememberWriteScope: String, Sendable, Equatable {
        case session
        case durable
    }

    package struct Remember: Sendable, Equatable {
        package var content: String
        package var sessionID: UUID?
        package var writeScope: RememberWriteScope?
        package var metadata: [String: String]
        package var writeSemantics: MemoryWriteSemantics
        package var cwd: String?
    }

    package struct ParsedSearchFilters: Sendable, Equatable {
        package var sessionId: UUID?
        package var frameFilter: FrameFilter?
        package var timeRange: SearchTimeRange?
        package var summary: AgentBrokerValue
    }

    package struct Recall: Sendable, Equatable {
        package var query: String
        package var limit: Int
        package var searchTopK: Int
        package var scope: LayeredRecall.Scope
        package var mode: RetrievalMode?
        package var filters: ParsedSearchFilters
        package var explicitProject: String?
        package var explicitRepo: String?
        package var clientCWD: String?
    }

    package struct Search: Sendable, Equatable {
        package var query: String
        package var mode: RetrievalMode
        package var topK: Int
        package var filters: ParsedSearchFilters
    }

    package struct MemorySearch: Sendable, Equatable {
        package var query: String
        package var mode: RetrievalMode
        package var topK: Int
        package var sessionID: UUID?
        package var includeWorking: Bool
        package var includeEpisodic: Bool
        package var includeDurable: Bool
    }

    package struct SessionStart: Sendable, Equatable {
        package var sessionID: UUID?
        package var agentID: String?
        package var runID: String?
        package var cwd: String?
        package var project: String?
        package var repo: String?
    }

    package struct SessionResume: Sendable, Equatable {
        package var sessionID: UUID?
        package var agentID: String?
        package var runID: String?
    }

    package struct SessionEnd: Sendable, Equatable {
        package var sessionID: UUID?
    }

    package struct Handoff: Sendable, Equatable {
        package var content: String
        package var sessionID: UUID?
        package var project: String?
        package var pendingTasks: [String]
    }

    package struct HandoffLatest: Sendable, Equatable {
        package var project: String?
    }

    package struct MemoryGet: Sendable, Equatable {
        package var memoryID: String
    }

    package struct Stats: Sendable, Equatable {
        package var sessionID: UUID?
    }

    package struct MarkdownSync: Sendable, Equatable {
        package var rootDir: String
        package var dryRun: Bool
    }

    package struct EntityUpsert: Sendable, Equatable {
        package var key: String
        package var kind: String
        package var aliases: [String]
    }

    package struct EntityResolve: Sendable, Equatable {
        package var alias: String
        package var limit: Int
    }

    package struct FactRetract: Sendable, Equatable {
        package var factID: Int64
        package var atMs: Int64?
    }

    /// Validates the argument surface and decodes a typed command (or passthrough).
    package static func decode(
        command rawCommand: String,
        arguments: [String: AgentBrokerValue]
    ) throws -> BrokerCommand {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try AgentBrokerCommandSurface.validateArgumentSurface(
            command: command,
            providedKeys: Set(arguments.keys)
        )
        let args = BrokerArguments(arguments)
        switch command {
        case "remember":
            return .remember(try Remember.decode(args))
        case "memory_append":
            return .memoryAppend(try Remember.decode(args))
        case "recall":
            return .recall(try Recall.decode(args))
        case "search":
            return .search(try Search.decode(args))
        case "memory_search":
            return .memorySearch(try MemorySearch.decode(args))
        case "session_start":
            return .sessionStart(try SessionStart.decode(args))
        case "session_resume":
            return .sessionResume(try SessionResume.decode(args))
        case "session_end":
            return .sessionEnd(try SessionEnd.decode(args))
        case "handoff":
            return .handoff(try Handoff.decode(args))
        case "handoff_latest":
            return .handoffLatest(try HandoffLatest.decode(args))
        case "memory_get":
            return .memoryGet(try MemoryGet.decode(args))
        case "memory_health":
            return .memoryHealth
        case "stats":
            return .stats(try Stats.decode(args))
        case "flush":
            return .flush
        case "markdown_sync":
            return .markdownSync(try MarkdownSync.decode(args))
        case "entity_upsert":
            return .entityUpsert(try EntityUpsert.decode(args))
        case "entity_resolve":
            return .entityResolve(try EntityResolve.decode(args))
        case "fact_retract":
            return .factRetract(try FactRetract.decode(args))
        case "shutdown", "exit", "quit":
            return .shutdown
        default:
            return .passthrough(command: command, arguments: arguments)
        }
    }
}

// MARK: - Payload decode

extension BrokerCommand.Remember {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        let content = try args.requiredStringPreservingWhitespace(
            "content",
            maxBytes: BrokerLimits.maxContentBytes
        )
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
        return Self(
            content: content,
            sessionID: sessionID,
            writeScope: writeScope,
            metadata: rawMetadata,
            writeSemantics: try BrokerCommand.parseWriteSemantics(args),
            cwd: try args.optionalString("cwd")
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
        if scope == .session, filters.sessionId == nil {
            throw BrokerValidationError.invalid("scope session requires session_id")
        }
        let mode = try BrokerCommand.parseRecallMode(args)
        let requestedTopK = try args.optionalInt("search_top_k") ?? (try args.optionalInt("topK"))
        if let requestedTopK, !(1...BrokerLimits.maxTopK).contains(requestedTopK) {
            throw BrokerValidationError.invalid(
                "search_top_k must be between 1 and \(BrokerLimits.maxTopK)"
            )
        }
        return Self(
            query: query,
            limit: limit,
            searchTopK: requestedTopK ?? limit,
            scope: scope,
            mode: mode,
            filters: filters,
            explicitProject: try args.optionalString("project"),
            explicitRepo: try args.optionalString("repo"),
            clientCWD: try args.optionalString("cwd")
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
        return Self(
            query: query,
            mode: mode,
            topK: topK,
            sessionID: try BrokerCommand.parseOptionalSessionID(args),
            includeWorking: try args.optionalBool("include_working") ?? true,
            includeEpisodic: try args.optionalBool("include_episodic") ?? true,
            includeDurable: try args.optionalBool("include_durable") ?? true
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
            repo: BrokerCommand.normalizedOrNil(try args.optionalString("repo"))
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
        Self(memoryID: try args.requiredString("memory_id", maxBytes: BrokerLimits.maxMemoryIDBytes))
    }
}

extension BrokerCommand.Stats {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(sessionID: try BrokerCommand.parseOptionalSessionID(args))
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
            key: try args.requiredString("key", maxBytes: BrokerLimits.maxGraphIdentifierBytes),
            kind: try args.requiredString("kind", maxBytes: BrokerLimits.maxGraphKindBytes),
            aliases: try args.optionalStringArray("aliases") ?? []
        )
    }
}

extension BrokerCommand.EntityResolve {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            alias: try args.requiredString("alias", maxBytes: BrokerLimits.maxGraphIdentifierBytes),
            limit: try args.optionalInt("limit") ?? 10
        )
    }
}

extension BrokerCommand.FactRetract {
    package static func decode(_ args: BrokerArguments) throws -> Self {
        Self(
            factID: try args.requiredInt64("fact_id"),
            atMs: try args.optionalInt64("at_ms")
        )
    }
}

// MARK: - Pure parsers

extension BrokerCommand {
    package static func parseOptionalSessionID(_ args: BrokerArguments) throws -> UUID? {
        guard let raw = try args.optionalString("session_id") else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw BrokerValidationError.invalid("session_id must be a valid UUID")
        }
        return value
    }

    package static func requireNonEmptyQuery(_ args: BrokerArguments) throws -> String {
        let query = try args.requiredString("query", maxBytes: BrokerLimits.maxContentBytes)
        guard !query.isEmpty else {
            throw BrokerValidationError.invalid("query must not be empty")
        }
        return query
    }

    package static func normalizedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package static func parseRememberWriteScope(_ args: BrokerArguments) throws -> RememberWriteScope? {
        guard let raw = try args.optionalString("scope")?.lowercased() else { return nil }
        guard let scope = RememberWriteScope(rawValue: raw) else {
            throw BrokerValidationError.invalid("scope must be one of: session, durable")
        }
        return scope
    }

    package static func parseRecallScope(_ args: BrokerArguments) throws -> LayeredRecall.Scope {
        let raw = try args.optionalString("scope")?.lowercased() ?? LayeredRecall.Scope.project.rawValue
        guard let scope = LayeredRecall.Scope(rawValue: raw) else {
            throw BrokerValidationError.invalid("scope must be one of: project, session, global")
        }
        return scope
    }

    package static func parseRecallMode(_ args: BrokerArguments) throws -> RetrievalMode? {
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let alpha = try args.optionalDouble("alpha")

        guard let modeRaw else {
            if let alpha {
                return .hybrid(alpha: try validatedHybridAlpha(alpha))
            }
            return nil
        }
        if alpha != nil, modeRaw != "hybrid" {
            throw BrokerValidationError.invalid("alpha is only valid when mode=hybrid")
        }

        switch modeRaw {
        case "text":
            return .textOnly
        case "vector":
            return .vectorOnly
        case "hybrid":
            return .hybrid(alpha: try validatedHybridAlpha(alpha ?? 0.5))
        default:
            throw BrokerValidationError.invalid("mode must be one of: text, vector, hybrid")
        }
    }

    package static func parseSearchMode(
        modeRaw: String?,
        alpha: Double?
    ) throws -> RetrievalMode {
        let resolvedMode = modeRaw ?? "text"
        if alpha != nil, resolvedMode != "hybrid" {
            throw BrokerValidationError.invalid("alpha is only valid when mode=hybrid")
        }
        let validatedAlpha = try validatedHybridAlpha(alpha ?? 0.5)
        switch resolvedMode {
        case "text":
            return .textOnly
        case "vector":
            return .vectorOnly
        case "hybrid":
            return .hybrid(alpha: validatedAlpha)
        default:
            throw BrokerValidationError.invalid("mode must be one of: text, vector, hybrid")
        }
    }

    package static func validatedHybridAlpha(_ alpha: Double) throws -> Float {
        guard (0.0...1.0).contains(alpha) else {
            throw BrokerValidationError.invalid("alpha must be between 0 and 1")
        }
        return Float(alpha)
    }

    package static func coerceMetadata(_ object: [String: AgentBrokerValue]?) throws -> [String: String] {
        guard let object else { return [:] }
        return try object.reduce(into: [String: String]()) { partial, entry in
            switch entry.value {
            case .string(let value):
                partial[entry.key] = value
            case .bool(let value):
                partial[entry.key] = value ? "true" : "false"
            case .int(let value):
                partial[entry.key] = String(value)
            case .double(let value):
                partial[entry.key] = String(value)
            default:
                throw BrokerValidationError.invalid("metadata.\(entry.key) must be a scalar")
            }
        }
    }

    package static func parseWriteSemantics(_ args: BrokerArguments) throws -> MemoryWriteSemantics {
        let type = try args.optionalString("memory_type").flatMap(MemoryType.init(rawValue:))
        if try args.optionalString("memory_type") != nil, type == nil {
            throw BrokerValidationError.invalid(
                "memory_type must be one of: \(MemoryType.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        let durability = try args.optionalString("durability").flatMap(MemoryDurability.init(rawValue:))
        if try args.optionalString("durability") != nil, durability == nil {
            throw BrokerValidationError.invalid(
                "durability must be one of: \(MemoryDurability.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return MemoryWriteSemantics(
            type: type,
            durability: durability,
            project: try args.optionalString("project"),
            repo: try args.optionalString("repo"),
            confidence: try args.optionalFloat("confidence"),
            expiresInDays: try args.optionalInt("expires_in_days"),
            reviewed: try args.optionalBool("reviewed") ?? false,
            lock: try args.optionalBool("locked") ?? false
        )
    }

    package static func parseSearchFilters(_ args: BrokerArguments) throws -> ParsedSearchFilters {
        let sessionID = try parseOptionalSessionID(args)
        let filters = try args.optionalObject("filters")

        var metadataEntries: [String: String] = [:]
        var labels: [String] = []
        var includeDeleted = false
        var includeSuperseded = false
        var includeSurrogates = false
        var frameIds: Set<UInt64>?
        var timeAfterMs: Int64?
        var timeBeforeMs: Int64?

        if let filters {
            let allowedFilterKeys: Set<String> = [
                "metadata",
                "labels",
                "include_deleted",
                "include_superseded",
                "include_surrogates",
                "frame_ids",
                "time_after_ms",
                "time_before_ms",
            ]
            let unknownFilterKeys = Set(filters.keys).subtracting(allowedFilterKeys)
            guard unknownFilterKeys.isEmpty else {
                let names = unknownFilterKeys.sorted().map { "filters.\($0)" }.joined(separator: ", ")
                throw BrokerValidationError.invalid("unsupported filter key(s): \(names)")
            }

            if let metadataRaw = filters["metadata"] {
                guard let metadataObject = metadataRaw.objectValue else {
                    throw BrokerValidationError.invalid("filters.metadata must be an object")
                }
                if let exact = metadataObject["exact"] {
                    guard metadataObject.count == 1 else {
                        throw BrokerValidationError.invalid(
                            "filters.metadata may be either a flat object or {\"exact\": {...}}"
                        )
                    }
                    guard let exactObject = exact.objectValue else {
                        throw BrokerValidationError.invalid("filters.metadata.exact must be an object")
                    }
                    metadataEntries = try coerceMetadata(exactObject)
                } else {
                    metadataEntries = try coerceMetadata(metadataObject)
                }
            }
            if let labelsRaw = filters["labels"] {
                guard let rawArray = labelsRaw.arrayValue else {
                    throw BrokerValidationError.invalid("filters.labels must be an array of strings")
                }
                labels = try rawArray.map { value in
                    guard let raw = value.stringValue else {
                        throw BrokerValidationError.invalid("filters.labels must contain only strings")
                    }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw BrokerValidationError.invalid("filters.labels must not contain empty values")
                    }
                    return trimmed
                }
            }
            if let includeRaw = filters["include_deleted"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_deleted must be a boolean")
                }
                includeDeleted = parsed
            }
            if let includeRaw = filters["include_superseded"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_superseded must be a boolean")
                }
                includeSuperseded = parsed
            }
            if let includeRaw = filters["include_surrogates"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_surrogates must be a boolean")
                }
                includeSurrogates = parsed
            }
            if let frameIdsRaw = filters["frame_ids"] {
                guard let rawArray = frameIdsRaw.arrayValue else {
                    throw BrokerValidationError.invalid(
                        "filters.frame_ids must be an array of non-negative integers"
                    )
                }
                var parsedFrameIds = Set<UInt64>()
                parsedFrameIds.reserveCapacity(rawArray.count)
                for value in rawArray {
                    guard case .int(let raw) = value, raw >= 0 else {
                        throw BrokerValidationError.invalid(
                            "filters.frame_ids must contain only non-negative integers"
                        )
                    }
                    parsedFrameIds.insert(UInt64(raw))
                }
                frameIds = parsedFrameIds
            }
            if let timeAfterRaw = filters["time_after_ms"] {
                guard let parsed = timeAfterRaw.intValue else {
                    throw BrokerValidationError.invalid("filters.time_after_ms must be an integer")
                }
                timeAfterMs = parsed
            }
            if let timeBeforeRaw = filters["time_before_ms"] {
                guard let parsed = timeBeforeRaw.intValue else {
                    throw BrokerValidationError.invalid("filters.time_before_ms must be an integer")
                }
                timeBeforeMs = parsed
            }
        }
        let metadataFilter: MetadataFilter? = (!metadataEntries.isEmpty || !labels.isEmpty)
            ? MetadataFilter(requiredEntries: metadataEntries, requiredLabels: labels)
            : nil
        let frameFilter: FrameFilter? =
            (metadataFilter != nil || includeDeleted || includeSuperseded || includeSurrogates
                || frameIds != nil)
            ? FrameFilter(
                includeDeleted: includeDeleted,
                includeSuperseded: includeSuperseded,
                includeSurrogates: includeSurrogates,
                frameIds: frameIds,
                metadataFilter: metadataFilter
            )
            : nil
        let timeRange: SearchTimeRange? = (timeAfterMs != nil || timeBeforeMs != nil)
            ? SearchTimeRange(after: timeAfterMs, before: timeBeforeMs)
            : nil
        return ParsedSearchFilters(
            sessionId: sessionID,
            frameFilter: frameFilter,
            timeRange: timeRange,
            summary: .object([
                "session_id": .from(sessionID?.uuidString),
                "metadata": .object(metadataEntries.mapValues(AgentBrokerValue.string)),
                "labels": .array(labels.map(AgentBrokerValue.string)),
                "time_after_ms": .from(timeAfterMs),
                "time_before_ms": .from(timeBeforeMs),
                "include_deleted": .from(includeDeleted),
                "include_superseded": .from(includeSuperseded),
                "include_surrogates": .from(includeSurrogates),
                "frame_ids": .array((frameIds ?? []).sorted().map(AgentBrokerValue.from)),
                "has_frame_filter": .from(frameFilter != nil),
                "has_time_range": .from(timeRange != nil),
            ])
        )
    }
}
