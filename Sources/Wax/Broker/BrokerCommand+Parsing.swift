import Foundation
import WaxCore

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

    package static func parseResponseVerbosity(_ args: BrokerArguments) throws -> ResponseVerbosity {
        guard let raw = try args.optionalString("verbosity") else { return .compact }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let verbosity = ResponseVerbosity(rawValue: trimmed) else {
            throw BrokerValidationError.invalid("verbosity must be one of: compact, verbose")
        }
        return verbosity
    }

    package static func parseRecallMode(_ args: BrokerArguments) throws -> SearchMode? {
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
            guard let alpha else { return .hybrid() }
            return .hybrid(alpha: try validatedHybridAlpha(alpha))
        default:
            throw BrokerValidationError.invalid("mode must be one of: text, vector, hybrid")
        }
    }

    package static func parseSearchMode(
        modeRaw: String?,
        alpha: Double?
    ) throws -> SearchMode {
        let resolvedMode = modeRaw ?? "text"
        if alpha != nil, resolvedMode != "hybrid" {
            throw BrokerValidationError.invalid("alpha is only valid when mode=hybrid")
        }
        switch resolvedMode {
        case "text":
            return .textOnly
        case "vector":
            return .vectorOnly
        case "hybrid":
            guard let alpha else { return .hybrid() }
            return .hybrid(alpha: try validatedHybridAlpha(alpha))
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
        let checkoutRaw = try args.optionalString("checkout_status")
        let checkoutStatus = checkoutRaw.flatMap(MemoryCheckoutStatus.init(rawValue:))
        if checkoutRaw != nil, checkoutStatus == nil {
            throw BrokerValidationError.invalid("checkout_status must be one of: intent, landed")
        }
        let confidence: Float?
        if let rawConfidence = try args.optionalDouble("confidence") {
            guard rawConfidence.isFinite, (0...1).contains(rawConfidence) else {
                throw BrokerValidationError.invalid("confidence must be a finite number between 0 and 1")
            }
            confidence = Float(rawConfidence)
        } else {
            confidence = nil
        }
        let expiresInDays = try args.optionalInt("expires_in_days")
        if let expiresInDays {
            guard (1...3650).contains(expiresInDays) else {
                throw BrokerValidationError.invalid("expires_in_days must be between 1 and 3650")
            }
        }
        return MemoryWriteSemantics(
            type: type,
            durability: durability,
            project: try args.optionalString("project"),
            repo: try args.optionalString("repo"),
            confidence: confidence,
            expiresInDays: expiresInDays,
            reviewed: try args.optionalBool("reviewed") ?? false,
            lock: try args.optionalBool("locked") ?? false,
            checkoutStatus: checkoutStatus
        )
    }

    /// Promotion/synthesis confidence threshold. Rejects out-of-range values
    /// like `remember` does instead of silently clamping: these thresholds
    /// select which items qualify, so a clamped value would promote a
    /// different set than the caller asked for.
    package static func parseMinimumConfidence(_ args: BrokerArguments) throws -> Float? {
        guard let raw = try args.optionalDouble("minimum_confidence") else { return nil }
        guard raw.isFinite, (0...1).contains(raw) else {
            throw BrokerValidationError.invalid("minimum_confidence must be a finite number between 0 and 1")
        }
        return Float(raw)
    }

    /// Promotion/synthesis recall-count threshold. Negative counts are
    /// rejected rather than clamped to zero for the same reason.
    package static func parseMinimumRecallCount(_ args: BrokerArguments) throws -> Int? {
        guard let value = try args.optionalInt("minimum_recall_count") else { return nil }
        guard value >= 0 else {
            throw BrokerValidationError.invalid("minimum_recall_count must be a non-negative integer")
        }
        return value
    }

    package static func parseMemoryTypes(_ args: BrokerArguments) throws -> [MemoryType] {
        guard let raw = try args.optionalStringArray("memory_types") else { return [] }
        return try raw.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let type = MemoryType(rawValue: trimmed) else {
                throw BrokerValidationError.invalid(
                    "memory_types must be one of: \(MemoryType.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            return type
        }
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
