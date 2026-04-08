#if MCPServer
import Foundation
import MCP
import Wax

enum WaxMCPTools {
    static func register(
        on server: Server,
        brokerConfiguration: AgentBrokerConfiguration,
        structuredMemoryEnabled: Bool,
        noEmbedder: Bool
    ) async {
        _ = await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
                tools: ToolSchemas.tools(structuredMemoryEnabled: structuredMemoryEnabled),
                nextCursor: nil
            )
        }

        _ = await server.withMethodHandler(CallTool.self) { params in
            await handleCall(
                params: params,
                brokerConfiguration: brokerConfiguration,
                structuredMemoryEnabled: structuredMemoryEnabled,
                noEmbedder: noEmbedder
            )
        }
    }

    static func handleCall(
        params: CallTool.Parameters,
        brokerConfiguration: AgentBrokerConfiguration,
        structuredMemoryEnabled: Bool = true,
        noEmbedder _: Bool = false
    ) async -> CallTool.Result {
        do {
            if let migration = migratedName(for: params.name) {
                return errorResult(
                    message: "tool '\(params.name)' has been renamed to '\(migration)'",
                    code: "tool_renamed"
                )
            }

            try validateToolAvailability(name: params.name, structuredMemoryEnabled: structuredMemoryEnabled)
            try validateArgumentSurface(name: params.name, arguments: params.arguments)

            let response = try await AgentBrokerClient.perform(
                request: AgentBrokerRequest(
                    command: params.name,
                    arguments: (params.arguments ?? [:]).mapValues(brokerValue(from:))
                ),
                configuration: brokerConfiguration
            )

            guard response.ok else {
                let message = response.error ?? "Broker execution failed"
                return errorResult(message: message, code: errorCode(for: message))
            }

            guard let payload = response.payload else {
                return errorResult(message: "Broker returned an empty payload", code: "execution_failed")
            }
            return renderResult(name: params.name, payload: payload)
        } catch let error as ToolValidationError {
            return errorResult(message: error.localizedDescription, code: "invalid_arguments")
        } catch {
            return errorResult(message: error.localizedDescription, code: "execution_failed")
        }
    }
}

private extension WaxMCPTools {
    static let readOnlyTextCommands: Set<String> = ["recall", "search", "corpus_search"]
    static let structuredCommands: Set<String> = ["entity_upsert", "fact_assert", "fact_retract", "facts_query", "entity_resolve"]
    static let commandArguments: [String: Set<String>] = [
        "remember": ["content", "session_id", "metadata"],
        "recall": ["query", "limit", "session_id", "mode", "alpha", "search_top_k", "topK", "filters"],
        "search": ["query", "mode", "topK", "session_id", "alpha", "filters"],
        "corpus_search": ["query", "rebuild", "recursive", "mode", "alpha", "topK"],
        "flush": [],
        "stats": [],
        "session_start": [],
        "session_end": ["session_id"],
        "handoff": ["content", "session_id", "project", "pending_tasks"],
        "handoff_latest": ["project"],
        "entity_upsert": ["key", "kind", "aliases"],
        "fact_assert": ["subject", "predicate", "object", "relation", "valid_from", "valid_to"],
        "fact_retract": ["fact_id"],
        "facts_query": ["subject", "predicate", "limit"],
        "entity_resolve": ["alias", "limit"],
    ]

    static func validateToolAvailability(name: String, structuredMemoryEnabled: Bool) throws {
        if structuredCommands.contains(name), !structuredMemoryEnabled {
            throw ToolValidationError.invalid("tool '\(name)' requires structured memory to be enabled")
        }
        guard commandArguments[name] != nil else {
            throw ToolValidationError.invalid("Unknown tool '\(name)'.")
        }
    }

    static func validateArgumentSurface(name: String, arguments: [String: Value]?) throws {
        let allowed = commandArguments[name] ?? []
        let provided = arguments.map { Set($0.keys) } ?? []
        let unknown = provided.subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolValidationError.invalid("unsupported argument(s): \(unknown.sorted().joined(separator: ", "))")
        }
    }

    static func migratedName(for name: String) -> String? {
        switch name {
        case "wax_remember": return "remember"
        case "wax_recall": return "recall"
        case "wax_search": return "search"
        case "wax_corpus_search": return "corpus_search"
        case "wax_flush": return "flush"
        case "wax_stats": return "stats"
        case "wax_session_start": return "session_start"
        case "wax_session_end": return "session_end"
        case "wax_handoff": return "handoff"
        case "wax_handoff_latest": return "handoff_latest"
        case "wax_entity_upsert": return "entity_upsert"
        case "wax_fact_assert": return "fact_assert"
        case "wax_fact_retract": return "fact_retract"
        case "wax_facts_query": return "facts_query"
        case "wax_entity_resolve": return "entity_resolve"
        default: return nil
        }
    }

    static func errorCode(for message: String) -> String {
        if message.hasPrefix("Missing required argument") || message.contains("must") || message.contains("unsupported argument") {
            return "invalid_arguments"
        }
        return "execution_failed"
    }

    static func renderResult(name: String, payload: AgentBrokerValue) -> CallTool.Result {
        let mcpPayload = mcpValue(from: removingDisplayText(from: payload))
        let text = payload.objectValue?["display_text"]?.stringValue

        if readOnlyTextCommands.contains(name) {
            let uri = switch name {
            case "recall": "wax://tool/recall-summary"
            case "search": "wax://tool/search-summary"
            case "corpus_search": "wax://tool/corpus-search-summary"
            default: "wax://tool/result"
            }
            return textWithJSONResourceResult(text: text ?? "", payload: mcpPayload, uri: uri)
        }

        return jsonResult(mcpPayload)
    }

    static func removingDisplayText(from payload: AgentBrokerValue) -> AgentBrokerValue {
        guard case .object(var object) = payload else { return payload }
        object.removeValue(forKey: "display_text")
        return .object(object)
    }

    static func textWithJSONResourceResult(
        text: String,
        payload: Value,
        uri: String = "wax://tool/result"
    ) -> CallTool.Result {
        let json = encodeJSON(payload) ?? "{}"
        return CallTool.Result(
            content: [
                .text(text: text, annotations: nil, _meta: nil),
                .resource(resource: .text(json, uri: uri, mimeType: "application/json")),
            ],
            isError: false
        )
    }

    static func jsonResult(_ value: Value) -> CallTool.Result {
        let json = encodeJSON(value) ?? "{}"
        return CallTool.Result(
            content: [
                .text(text: json, annotations: nil, _meta: nil),
                .resource(resource: .text(json, uri: "wax://tool/result", mimeType: "application/json")),
            ],
            isError: false
        )
    }

    static func errorResult(message: String, code: String) -> CallTool.Result {
        let payload: Value = [
            "code": .string(code),
            "message": .string(message),
        ]
        let json = encodeJSON(payload) ?? "{}"
        return CallTool.Result(
            content: [
                .text(text: message, annotations: nil, _meta: nil),
                .resource(resource: .text(json, uri: "wax://errors/\(code)", mimeType: "application/json")),
            ],
            isError: true
        )
    }

    static func encodeJSON(_ value: Value) -> String? {
        let object = toJSONObject(value)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func toJSONObject(_ value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .data(_, let data):
            return data.base64EncodedString()
        case .array(let values):
            return values.map(toJSONObject)
        case .object(let values):
            return values.mapValues(toJSONObject)
        }
    }
}

private enum ToolValidationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

// Compatibility path for the existing direct-memory unit tests. Production MCP calls go
// through the broker-backed overload above; this shim keeps the current test suite usable
// while the tests are migrated to broker semantics.
private actor CompatSessionRegistryPool {
    private var registries: [ObjectIdentifier: CompatSessionRegistry] = [:]

    func registry(for memory: MemoryOrchestrator) -> CompatSessionRegistry {
        let key = ObjectIdentifier(memory)
        if let existing = registries[key] {
            return existing
        }
        let created = CompatSessionRegistry()
        registries[key] = created
        return created
    }
}

private actor CompatSessionRegistry {
    private var activeSessions: Set<UUID> = []

    func start() -> UUID {
        let sessionID = UUID()
        activeSessions.insert(sessionID)
        return sessionID
    }

    func end(sessionID: UUID?) throws -> (UUID?, Bool) {
        if let sessionID {
            guard activeSessions.remove(sessionID) != nil else {
                throw ToolValidationError.invalid("session_id is not active in this server process; call wax_session_start again")
            }
            return (sessionID, !activeSessions.isEmpty)
        }

        switch activeSessions.count {
        case 0:
            return (nil, false)
        case 1:
            return (activeSessions.removeFirst(), false)
        default:
            throw ToolValidationError.invalid("session_id is required when more than one MCP session is active")
        }
    }

    func isActive(_ sessionID: UUID) -> Bool {
        activeSessions.contains(sessionID)
    }

    func activeSessionIDs() -> [UUID] {
        Array(activeSessions)
    }
}

private let compatSessionRegistries = CompatSessionRegistryPool()

extension WaxMCPTools {
    static func handleCall(
        params: CallTool.Parameters,
        memory: MemoryOrchestrator,
        structuredMemoryEnabled: Bool = true,
        noEmbedder: Bool = false,
        embedderChoice: String = "minilm"
    ) async -> CallTool.Result {
        let sessionRegistry = await compatSessionRegistries.registry(for: memory)
        do {
            let normalizedName = migratedName(for: params.name) ?? params.name.replacingOccurrences(of: "wax_", with: "")
            if normalizedName != "flush" {
                try validateToolAvailability(name: normalizedName, structuredMemoryEnabled: structuredMemoryEnabled)
            }
            try validateArgumentSurface(name: normalizedName, arguments: params.arguments)

            switch normalizedName {
            case "remember":
                return try await compatRemember(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "recall":
                return try await compatRecall(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "search":
                return try await compatSearch(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "corpus_search":
                return try await compatCorpusSearch(params.arguments, noEmbedder: noEmbedder, embedderChoice: embedderChoice)
            case "flush":
                return try await compatFlush(memory)
            case "stats":
                return try await compatStats(memory, sessionRegistry: sessionRegistry)
            case "session_start":
                return await compatSessionStart(sessionRegistry)
            case "session_end":
                return try await compatSessionEnd(params.arguments, sessionRegistry: sessionRegistry)
            case "handoff":
                return try await compatHandoff(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "handoff_latest":
                return try await compatHandoffLatest(params.arguments, memory: memory)
            case "entity_upsert" where structuredMemoryEnabled:
                return try await compatEntityUpsert(params.arguments, memory: memory)
            case "fact_assert" where structuredMemoryEnabled:
                return try await compatFactAssert(params.arguments, memory: memory)
            case "fact_retract" where structuredMemoryEnabled:
                return try await compatFactRetract(params.arguments, memory: memory)
            case "facts_query" where structuredMemoryEnabled:
                return try await compatFactsQuery(params.arguments, memory: memory)
            case "entity_resolve" where structuredMemoryEnabled:
                return try await compatEntityResolve(params.arguments, memory: memory)
            case "entity_upsert", "fact_assert", "fact_retract", "facts_query", "entity_resolve":
                return errorResult(message: "tool '\(normalizedName)' requires structured memory to be enabled", code: "feature_disabled")
            default:
                return errorResult(message: "Unknown tool '\(params.name)'.", code: "unknown_tool")
            }
        } catch let error as ToolValidationError {
            return errorResult(message: error.localizedDescription, code: "invalid_arguments")
        } catch {
            return errorResult(message: error.localizedDescription, code: "execution_failed")
        }
    }
}

private extension WaxMCPTools {
    struct CompatArguments {
        let values: [String: Value]

        init(_ values: [String: Value]?) {
            self.values = values ?? [:]
        }

        func requiredString(_ key: String) throws -> String {
            guard let value = values[key] else { throw ToolValidationError.invalid("Missing required argument '\(key)'.") }
            guard case .string(let text) = value else {
                throw ToolValidationError.invalid("\(key) must be a string")
            }
            return text
        }

        func optionalString(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            guard case .string(let text) = value else {
                throw ToolValidationError.invalid("\(key) must be a string")
            }
            return text
        }

        func optionalInt(_ key: String) throws -> Int? {
            guard let value = values[key] else { return nil }
            switch value {
            case .int(let int):
                return int
            case .double(let double):
                guard double.isFinite else {
                    throw ToolValidationError.invalid("\(key) is out of range")
                }
                guard double.rounded() == double else {
                    throw ToolValidationError.invalid("\(key) must be an integer")
                }
                guard double >= Double(Int.min), double <= Double(Int.max) else {
                    throw ToolValidationError.invalid("\(key) is out of range")
                }
                return Int(double)
            default:
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
        }

        func optionalInt64(_ key: String) throws -> Int64? {
            guard let value = values[key] else { return nil }
            switch value {
            case .int(let int):
                return Int64(int)
            case .double(let double):
                guard double.isFinite else {
                    throw ToolValidationError.invalid("\(key) is out of range")
                }
                guard double.rounded() == double else {
                    throw ToolValidationError.invalid("\(key) must be an integer")
                }
                guard double >= Double(Int64.min), double <= Double(Int64.max) else {
                    throw ToolValidationError.invalid("\(key) is out of range")
                }
                return Int64(double)
            default:
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
        }

        func optionalDouble(_ key: String) throws -> Double? {
            guard let value = values[key] else { return nil }
            switch value {
            case .double(let double): return double
            case .int(let int): return Double(int)
            default: throw ToolValidationError.invalid("\(key) must be a number")
            }
        }

        func optionalBool(_ key: String) throws -> Bool? {
            guard let value = values[key] else { return nil }
            guard case .bool(let bool) = value else {
                throw ToolValidationError.invalid("\(key) must be a boolean")
            }
            return bool
        }

        func optionalObject(_ key: String) throws -> [String: Value]? {
            guard let value = values[key] else { return nil }
            guard case .object(let object) = value else {
                throw ToolValidationError.invalid("\(key) must be an object")
            }
            return object
        }

        func optionalStringArray(_ key: String) throws -> [String]? {
            guard let value = values[key] else { return nil }
            guard case .array(let array) = value else {
                throw ToolValidationError.invalid("\(key) must be an array")
            }
            return try array.map { element in
                guard case .string(let value) = element else {
                    throw ToolValidationError.invalid("\(key) must contain only strings")
                }
                return value
            }
        }

        func requiredValue(_ key: String) throws -> Value {
            guard let value = values[key] else { throw ToolValidationError.invalid("Missing required argument '\(key)'.") }
            return value
        }
    }

    struct CompatParsedFilters {
        let sessionID: UUID?
        let frameFilter: FrameFilter?
        let timeRange: SearchTimeRange?
        let summary: Value
    }

    static func compatParseSessionID(_ args: CompatArguments) throws -> UUID? {
        guard let raw = try args.optionalString("session_id") else { return nil }
        guard let sessionID = UUID(uuidString: raw) else {
            throw ToolValidationError.invalid("session_id must be a valid UUID")
        }
        return sessionID
    }

    static func compatValidateActiveSession(_ sessionID: UUID?, in registry: CompatSessionRegistry) async throws {
        guard let sessionID else { return }
        guard await registry.isActive(sessionID) else {
            throw ToolValidationError.invalid("session_id is not active in this server process; call wax_session_start again")
        }
    }

    static func compatCoerceMetadata(_ object: [String: Value]?) throws -> [String: String] {
        guard let object else { return [:] }
        return try object.reduce(into: [String: String]()) { partial, entry in
            switch entry.value {
            case .string(let text):
                partial[entry.key] = text
            case .bool(let bool):
                partial[entry.key] = bool ? "true" : "false"
            case .int(let int):
                partial[entry.key] = String(int)
            case .double(let double):
                partial[entry.key] = String(double)
            default:
                throw ToolValidationError.invalid("metadata.\(entry.key) must be a scalar")
            }
        }
    }

    static func compatParseSearchFilters(_ args: CompatArguments) throws -> CompatParsedFilters {
        let sessionID = try compatParseSessionID(args)
        let filters = try args.optionalObject("filters")
        var metadataEntries: [String: String] = [:]
        var labels: [String] = []
        var includeSurrogates = false
        var timeAfterMs: Int64?
        var timeBeforeMs: Int64?

        if let filters {
            if let metadataRaw = filters["metadata"] {
                guard case .object(let metadataObject) = metadataRaw else {
                    throw ToolValidationError.invalid("filters.metadata must be an object")
                }
                if let exact = metadataObject["exact"] {
                    guard case .object(let exactObject) = exact else {
                        throw ToolValidationError.invalid("filters.metadata.exact must be an object")
                    }
                    metadataEntries = try compatCoerceMetadata(exactObject)
                } else {
                    metadataEntries = try compatCoerceMetadata(metadataObject)
                }
            }
            if let labelsRaw = filters["labels"] {
                guard case .array(let rawLabels) = labelsRaw else {
                    throw ToolValidationError.invalid("filters.labels must be an array of strings")
                }
                labels = try rawLabels.map { element in
                    guard case .string(let raw) = element else {
                        throw ToolValidationError.invalid("filters.labels must contain only strings")
                    }
                    return raw
                }
            }
            if let includeRaw = filters["include_surrogates"] {
                guard case .bool(let value) = includeRaw else {
                    throw ToolValidationError.invalid("filters.include_surrogates must be a boolean")
                }
                includeSurrogates = value
            }
            if let timeAfterRaw = filters["time_after_ms"] {
                guard case .int(let value) = timeAfterRaw else {
                    throw ToolValidationError.invalid("filters.time_after_ms must be an integer")
                }
                timeAfterMs = Int64(value)
            }
            if let timeBeforeRaw = filters["time_before_ms"] {
                guard case .int(let value) = timeBeforeRaw else {
                    throw ToolValidationError.invalid("filters.time_before_ms must be an integer")
                }
                timeBeforeMs = Int64(value)
            }
        }
        if let sessionID {
            metadataEntries["session_id"] = sessionID.uuidString
        }
        let metadataFilter: MetadataFilter? = (!metadataEntries.isEmpty || !labels.isEmpty)
            ? MetadataFilter(requiredEntries: metadataEntries, requiredLabels: labels)
            : nil
        let frameFilter: FrameFilter? = (metadataFilter != nil || includeSurrogates)
            ? FrameFilter(includeSurrogates: includeSurrogates, metadataFilter: metadataFilter)
            : nil
        let timeRange: SearchTimeRange? = (timeAfterMs != nil || timeBeforeMs != nil)
            ? SearchTimeRange(after: timeAfterMs, before: timeBeforeMs)
            : nil
        return CompatParsedFilters(
            sessionID: sessionID,
            frameFilter: frameFilter,
            timeRange: timeRange,
            summary: [
                "session_id": sessionID.map { .string($0.uuidString) } ?? .null,
                "metadata": .object(metadataEntries.mapValues(Value.string)),
                "labels": .array(labels.map(Value.string)),
                "time_after_ms": timeAfterMs.map { .int(Int($0)) } ?? .null,
                "time_before_ms": timeBeforeMs.map { .int(Int($0)) } ?? .null,
                "include_surrogates": .bool(includeSurrogates),
                "has_frame_filter": .bool(frameFilter != nil),
                "has_time_range": .bool(timeRange != nil),
            ]
        )
    }

    static func compatRemember(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let content = try args.requiredString("content")
        let sessionID = try compatParseSessionID(args)
        try await compatValidateActiveSession(sessionID, in: sessionRegistry)
        var metadata = try compatCoerceMetadata(try args.optionalObject("metadata"))
        if metadata["session_id"] != nil {
            throw ToolValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        if let sessionID {
            metadata["session_id"] = sessionID.uuidString
        }
        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: metadata)
        if try args.optionalBool("commit") ?? true {
            try await memory.flush()
        }
        let after = await memory.runtimeStats()
        let added = max(0, Int((after.frameCount + after.pendingFrames) - (before.frameCount + before.pendingFrames)))
        return jsonResult([
            "status": .string("ok"),
            "framesAdded": .int(added),
            "frameCount": .int(Int(after.frameCount)),
            "pendingFrames": .int(Int(after.pendingFrames)),
        ])
    }

    static func compatRecall(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let query = try args.requiredString("query")
        let limit = try args.optionalInt("limit") ?? 5
        guard (1...100).contains(limit) else {
            throw ToolValidationError.invalid("limit must be between 1 and 100")
        }
        let filters = try compatParseSearchFilters(args)
        try await compatValidateActiveSession(filters.sessionID, in: sessionRegistry)
        let requestedTopK = try args.optionalInt("search_top_k") ?? (try args.optionalInt("topK"))
        let effectiveTopK = requestedTopK ?? limit
        guard (1...200).contains(effectiveTopK) else {
            throw ToolValidationError.invalid("search_top_k must be between 1 and 200")
        }
        let mode = try args.optionalString("mode") ?? "hybrid"
        guard mode == "text" || mode == "hybrid" else {
            throw ToolValidationError.invalid("mode must be one of: text, hybrid")
        }
        let directMode: MemoryOrchestrator.DirectSearchMode = mode == "text" ? .text : .hybrid(alpha: Float(try args.optionalDouble("alpha") ?? 0.5))
        let embeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy = mode == "text" ? .never : .ifAvailable
        let execution = try await memory.recallExecution(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: filters.frameFilter,
            timeRange: filters.timeRange,
            topK: effectiveTopK,
            mode: directMode
        )
        let context = execution.context
        let selected = Array(context.items.prefix(limit))
        let filterSummaryJSON = encodeJSON(filters.summary) ?? "{}"
        var lines: [String] = [
            "Query: \(context.query)",
            "Total tokens: \(context.totalTokens)",
            "Results: \(selected.count) of \(limit) requested (orchestrator returned \(context.items.count))",
            "Search controls: requested_mode=\(execution.requestedModeSummary) effective_mode=\(execution.effectiveModeSummary) query_embedding_state=\(execution.queryEmbeddingState.rawValue) search_top_k=\(effectiveTopK) limit=\(limit)",
            "Applied filters: \(filterSummaryJSON)",
        ]
        for (index, item) in selected.enumerated() {
            lines.append("\(index + 1). [\(item.kind)] frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) \(item.text)")
        }
        let results: [Value] = selected.enumerated().map { index, item in
            [
                "rank": .int(index + 1),
                "kind": .string("\(item.kind)"),
                "frameId": .int(Int(item.frameId)),
                "score": .double(Double(item.score)),
                "sources": .array(item.sources.map { .string($0.rawValue) }),
                "text": .string(item.text),
                "metadata": .object(item.metadata.mapValues(Value.string)),
            ]
        }
        return textWithJSONResourceResult(
            text: lines.joined(separator: "\n"),
            payload: [
                "query": .string(context.query),
                "total_tokens": .int(context.totalTokens),
                "result_count": .int(selected.count),
                "limit": .int(limit),
                "search_top_k": .int(effectiveTopK),
                "requested_mode": .string(execution.requestedModeSummary),
                "effective_mode": .string(execution.effectiveModeSummary),
                "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
                "applied_filters": filters.summary,
                "results": .array(results),
            ],
            uri: "wax://tool/recall-summary"
        )
    }

    static func compatSearch(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let query = try args.requiredString("query")
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...200).contains(topK) else {
            throw ToolValidationError.invalid("topK must be between 1 and 200")
        }
        let filters = try compatParseSearchFilters(args)
        try await compatValidateActiveSession(filters.sessionID, in: sessionRegistry)
        let modeRaw = try args.optionalString("mode") ?? "text"
        guard modeRaw == "text" || modeRaw == "hybrid" else {
            throw ToolValidationError.invalid("mode must be one of: text, hybrid")
        }
        let mode: MemoryOrchestrator.DirectSearchMode = modeRaw == "text" ? .text : .hybrid(alpha: Float(try args.optionalDouble("alpha") ?? 0.5))
        let execution = try await memory.searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: filters.frameFilter,
            timeRange: filters.timeRange
        )
        let rows: [Value] = execution.hits.enumerated().map { index, hit in
            [
                "rank": .int(index + 1),
                "frameId": .int(Int(hit.frameId)),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": .string(hit.previewText ?? ""),
                "metadata": .object(hit.metadata.mapValues(Value.string)),
            ]
        }
        let displayText = rows.isEmpty ? "No results." : rows.compactMap(encodeJSON).joined(separator: "\n")
        return textWithJSONResourceResult(
            text: displayText,
            payload: [
                "query": .string(query),
                "topK": .int(topK),
                "requested_mode": .string(execution.requestedModeSummary),
                "effective_mode": .string(execution.effectiveModeSummary),
                "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
                "applied_filters": filters.summary,
                "results": .array(rows),
            ],
            uri: "wax://tool/search-summary"
        )
    }

    static func compatFlush(_ memory: MemoryOrchestrator) async throws -> CallTool.Result {
        try await memory.flush()
        let stats = await memory.runtimeStats()
        return textWithJSONResourceResult(
            text: "Flushed. \(stats.frameCount) frames now searchable.",
            payload: [
                "status": .string("ok"),
                "frameCount": .int(Int(stats.frameCount)),
                "pendingFrames": .int(Int(stats.pendingFrames)),
            ],
            uri: "wax://tool/flush-summary"
        )
    }

    static func compatStats(_ memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let stats = await memory.runtimeStats()
        let activeSessions = await sessionRegistry.activeSessionIDs().sorted { $0.uuidString < $1.uuidString }
        let primarySessionID = activeSessions.count == 1 ? activeSessions.first : nil
        return jsonResult([
            "frameCount": .int(Int(stats.frameCount)),
            "pendingFrames": .int(Int(stats.pendingFrames)),
            "storePath": .string(stats.storeURL.path),
            "vectorSearchEnabled": .bool(stats.vectorSearchEnabled),
            "queryEmbeddingAvailable": .bool(
                stats.vectorSearchEnabled && stats.queryEmbedderConfigured && !stats.queryEmbeddingCircuitOpen
            ),
            "queryEmbeddingCircuitOpen": .bool(stats.queryEmbeddingCircuitOpen),
            "session": [
                "active": .bool(!activeSessions.isEmpty),
                "session_id": primarySessionID.map { .string($0.uuidString) } ?? .null,
                "activeSessionCount": .int(activeSessions.count),
                "activeSessionIds": .array(activeSessions.map { .string($0.uuidString) }),
                "sessionFrameCount": .int(primarySessionID == nil ? 0 : Int(stats.frameCount)),
            ],
        ])
    }

    static func compatSessionStart(_ sessionRegistry: CompatSessionRegistry) async -> CallTool.Result {
        let value = await sessionRegistry.start()
        return jsonResult([
            "status": .string("ok"),
            "session_id": .string(value.uuidString),
        ])
    }

    static func compatSessionEnd(_ arguments: [String: Value]?, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let sessionID = try compatParseSessionID(args)
        let result = try await sessionRegistry.end(sessionID: sessionID)
        return jsonResult([
            "status": .string("ok"),
            "session_id": result.0.map { .string($0.uuidString) } ?? .null,
            "active": .bool(result.1),
        ])
    }

    static func compatHandoff(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let content = try args.requiredString("content")
        let sessionID = try compatParseSessionID(args)
        try await compatValidateActiveSession(sessionID, in: sessionRegistry)
        let project = try args.optionalString("project")
        let pendingTasks = try args.optionalStringArray("pending_tasks") ?? []
        let commit = try args.optionalBool("commit") ?? true
        let frameId = try await memory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: commit
        )
        return jsonResult([
            "status": .string("ok"),
            "frame_id": .int(Int(frameId)),
            "committed": .bool(commit),
        ])
    }

    static func compatHandoffLatest(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let project = try args.optionalString("project")
        guard let latest = try await memory.latestHandoff(project: project) else {
            return jsonResult(["found": .bool(false)])
        }
        return jsonResult([
            "found": .bool(true),
            "frame_id": .int(Int(latest.frameId)),
            "timestamp_ms": .int(Int(latest.timestampMs)),
            "project": latest.project.map(Value.string) ?? .null,
            "pending_tasks": .array(latest.pendingTasks.map(Value.string)),
            "content": .string(latest.content),
        ])
    }

    static func compatEntityUpsert(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let key = try args.requiredString("key")
        let kind = try args.requiredString("kind")
        let aliases = try args.optionalStringArray("aliases") ?? []
        let entityID = try await memory.upsertEntity(key: EntityKey(key), kind: kind, aliases: aliases, commit: true)
        return jsonResult([
            "status": .string("ok"),
            "entity_id": .int(Int(entityID.rawValue)),
            "key": .string(key),
            "committed": .bool(true),
        ])
    }

    static func compatFactAssert(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let subject = try args.requiredString("subject")
        let predicate = try args.requiredString("predicate")
        let object = try compatFactValue(args.requiredValue("object"))
        let relation = try compatVersionRelation(try args.optionalString("relation") ?? "sets")
        let factID = try await memory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: object,
            relation: relation,
            validFromMs: try args.optionalInt64("valid_from"),
            validToMs: try args.optionalInt64("valid_to"),
            commit: true
        )
        return jsonResult([
            "status": .string("ok"),
            "fact_id": .int(Int(factID.rawValue)),
            "committed": .bool(true),
        ])
    }

    static func compatFactRetract(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let factID = try args.optionalInt("fact_id") ?? 0
        try await memory.retractFact(factId: FactRowID(rawValue: Int64(factID)), atMs: nil, commit: true)
        return jsonResult([
            "status": .string("ok"),
            "fact_id": .int(factID),
            "committed": .bool(true),
        ])
    }

    static func compatFactsQuery(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let limit = try args.optionalInt("limit") ?? 20
        let result = try await memory.facts(
            about: try args.optionalString("subject").map { EntityKey($0) },
            predicate: try args.optionalString("predicate").map { PredicateKey($0) },
            asOfMs: Int64.max,
            limit: limit
        )
        return jsonResult([
            "count": .int(result.hits.count),
            "truncated": .bool(result.wasTruncated),
            "hits": .array(result.hits.map { hit in
                [
                    "fact_id": .int(Int(hit.factId.rawValue)),
                    "subject": .string(hit.fact.subject.rawValue),
                    "predicate": .string(hit.fact.predicate.rawValue),
                    "object": compatFactValuePayload(hit.fact.object),
                ]
            }),
        ])
    }

    static func compatEntityResolve(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let alias = try args.requiredString("alias")
        let limit = try args.optionalInt("limit") ?? 10
        let matches = try await memory.resolveEntities(matchingAlias: alias, limit: limit)
        return jsonResult([
            "count": .int(matches.count),
            "entities": .array(matches.map { match in
                [
                    "id": .int(Int(match.id)),
                    "key": .string(match.key.rawValue),
                    "kind": .string(match.kind),
                ]
            }),
        ])
    }

    static func compatCorpusSearch(_ arguments: [String: Value]?, noEmbedder: Bool, embedderChoice: String) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let query = try args.requiredString("query")
        let sessionsDirRaw = try args.optionalString("sessions_dir") ?? "~/.wax/sessions"
        let corpusStoreRaw = try args.optionalString("corpus_store_path") ?? "~/.wax/corpus.wax"
        let rebuild = try args.optionalBool("rebuild") ?? true
        let recursive = try args.optionalBool("recursive") ?? true
        let modeRaw = try args.optionalString("mode") ?? "text"
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...200).contains(topK) else {
            throw ToolValidationError.invalid("topK must be between 1 and 200")
        }
        let corpusNoEmbedder = modeRaw == "text" ? true : noEmbedder
        let sessionsDirectoryURL = try MCPPathing.resolveDirectoryURL(sessionsDirRaw)
        let corpusStoreURL = try MCPPathing.resolveStoreURL(corpusStoreRaw)
        let buildSummary: CorpusBuildSummary?

        if rebuild || !FileManager.default.fileExists(atPath: corpusStoreURL.path) {
            buildSummary = try await CorpusStoreBuilder.build(
                sessionsDirectory: sessionsDirectoryURL,
                targetStoreURL: corpusStoreURL,
                noEmbedder: corpusNoEmbedder,
                embedderChoice: embedderChoice,
                recursive: recursive
            )
        } else {
            buildSummary = nil
        }

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpusStoreURL,
            noEmbedder: corpusNoEmbedder,
            embedderChoice: embedderChoice,
            structuredMemoryEnabled: false
        ) { corpusMemory in
            try await corpusMemory.searchExecution(
                query: query,
                mode: modeRaw == "text" ? .text : .hybrid(alpha: Float(try args.optionalDouble("alpha") ?? 0.5)),
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
        }
        let resultRows: [Value] = execution.hits.map { hit in
            [
                "frameId": .int(Int(hit.frameId)),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": .string(hit.previewText ?? ""),
                "metadata": .object(hit.metadata.mapValues(Value.string)),
            ]
        }
        let displayText = resultRows.isEmpty ? "No results." : resultRows.compactMap(encodeJSON).joined(separator: "\n")
        let buildPayload: Value = buildSummary.map { summary in
            .object([
                "performed": .bool(true),
                "stores_discovered": .int(summary.storesDiscovered),
                "stores_indexed": .int(summary.storesIndexed),
                "documents_indexed": .int(summary.documentsIndexed),
                "documents_skipped": .int(summary.documentsSkipped),
                "corpus_store_path": .string(summary.targetStorePath),
            ])
        } ?? .object([
            "performed": .bool(false),
            "corpus_store_path": .string(corpusStoreURL.path),
        ])
        return textWithJSONResourceResult(
            text: displayText,
            payload: [
                "query": .string(query),
                "topK": .int(topK),
                "requested_mode": .string(execution.requestedModeSummary),
                "effective_mode": .string(execution.effectiveModeSummary),
                "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
                "build": buildPayload,
                "results": .array(resultRows),
            ],
            uri: "wax://tool/corpus-search-summary"
        )
    }

    static func compatFactValue(_ value: Value) throws -> FactValue {
        switch value {
        case .string(let text):
            return .string(text)
        case .bool(let bool):
            return .bool(bool)
        case .int(let int):
            return .int(Int64(int))
        case .double(let double):
            return .double(double)
        case .object(let object):
            if let entity = object["entity"], case .string(let raw) = entity, object.count == 1 {
                return .entity(EntityKey(raw))
            }
            if let time = object["time_ms"], case .int(let raw) = time, object.count == 1 {
                return .timeMs(Int64(raw))
            }
            if let data = object["data_base64"], case .string(let raw) = data, object.count == 1, let decoded = Data(base64Encoded: raw) {
                return .data(decoded)
            }
            throw ToolValidationError.invalid("typed object values must be one of: entity, time_ms, data_base64")
        default:
            throw ToolValidationError.invalid("object must be a string, number, bool, or typed object")
        }
    }

    static func compatFactValuePayload(_ value: FactValue) -> Value {
        switch value {
        case .string(let s): return .string(s)
        case .int(let i): return .int(Int(i))
        case .double(let d): return .double(d)
        case .bool(let b): return .bool(b)
        case .entity(let key): return .object(["entity": .string(key.rawValue)])
        case .timeMs(let ms): return .object(["time_ms": .int(Int(ms))])
        case .data(let data): return .object(["data_base64": .string(data.base64EncodedString())])
        }
    }

    static func compatVersionRelation(_ raw: String) throws -> VersionRelation {
        switch raw.lowercased() {
        case "sets": return .sets
        case "updates": return .updates
        case "extends": return .extends
        case "retracts": return .retracts
        default: throw ToolValidationError.invalid("relation must be one of: sets, updates, extends, retracts")
        }
    }
}
#endif
