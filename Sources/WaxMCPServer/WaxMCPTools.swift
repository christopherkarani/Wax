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
    static let readOnlyTextCommands: Set<String> = ["recall", "search", "memory_search", "memory_get", "compact_context", "corpus_search", "session_synthesize", "memory_health"]
    static let structuredCommands: Set<String> = ["knowledge_capture", "entity_upsert", "fact_assert", "fact_retract", "facts_query", "entity_resolve"]

    static func validateToolAvailability(name: String, structuredMemoryEnabled: Bool) throws {
        if structuredCommands.contains(name), !structuredMemoryEnabled {
            throw ToolValidationError.invalid("tool '\(name)' requires structured memory to be enabled")
        }
        guard AgentBrokerCommandSurface.allowedPublicArguments(for: name) != nil else {
            throw ToolValidationError.invalid("Unknown tool '\(name)'.")
        }
    }

    static func validateArgumentSurface(name: String, arguments: [String: Value]?) throws {
        do {
            try AgentBrokerCommandSurface.validateArgumentSurface(
                command: name,
                providedKeys: arguments.map { Set($0.keys) } ?? []
            )
        } catch {
            throw ToolValidationError.invalid(error.localizedDescription)
        }
    }

    static func migratedName(for name: String) -> String? {
        switch name {
        case "wax_memory_append": return "memory_append"
        case "wax_memory_search": return "memory_search"
        case "wax_memory_get": return "memory_get"
        case "wax_remember": return "remember"
        case "wax_recall": return "recall"
        case "wax_search": return "search"
        case "wax_session_synthesize": return "session_synthesize"
        case "wax_memory_promote": return "memory_promote"
        case "wax_promote": return "promote"
        case "wax_memory_health": return "memory_health"
        case "wax_knowledge_capture": return "knowledge_capture"
        case "wax_corpus_search": return "corpus_search"
        case "wax_stats": return "stats"
        case "wax_session_start": return "session_start"
        case "wax_session_resume": return "session_resume"
        case "wax_session_end": return "session_end"
        case "wax_handoff": return "handoff"
        case "wax_handoff_latest": return "handoff_latest"
        case "wax_compact_context": return "compact_context"
        case "wax_markdown_export": return "markdown_export"
        case "wax_markdown_sync": return "markdown_sync"
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

    static func compatSearchMode(modeRaw: String, alpha: Double?) throws -> MemoryOrchestrator.DirectSearchMode {
        switch modeRaw {
        case "text":
            return .text
        case "vector":
            return .vector
        case "hybrid":
            return .hybrid(alpha: Float(alpha ?? 0.5))
        default:
            throw ToolValidationError.invalid("mode must be one of: text, vector, hybrid")
        }
    }

    static func compatEmbeddingPolicy(for mode: MemoryOrchestrator.DirectSearchMode) -> MemoryOrchestrator.QueryEmbeddingPolicy {
        switch mode {
        case .text:
            return .never
        case .vector:
            return .always
        case .hybrid:
            return .ifAvailable
        }
    }

    static func renderResult(name: String, payload: AgentBrokerValue) -> CallTool.Result {
        let mcpPayload = mcpValue(from: removingDisplayText(from: payload))
        let text = payload.objectValue?["display_text"]?.stringValue

        if readOnlyTextCommands.contains(name) {
            let uri = switch name {
            case "recall": "wax://tool/recall-summary"
            case "search": "wax://tool/search-summary"
            case "memory_search": "wax://tool/memory-search-summary"
            case "memory_get": "wax://tool/memory-get-summary"
            case "compact_context": "wax://tool/compact-context-summary"
            case "corpus_search": "wax://tool/corpus-search-summary"
            case "session_synthesize": "wax://tool/session-synthesize-summary"
            case "memory_health": "wax://tool/memory-health-summary"
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
    private struct CompatRecallTracker: Sendable {
        var recallCount: Int = 0
        var queryHashes: Set<String> = []
        var lastRetrievedAtMs: Int64?
        var scoreTotal: Float = 0
    }

    private var activeSessions: Set<UUID> = []
    private var recallTrackers: [UUID: [UInt64: CompatRecallTracker]] = [:]

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
            recallTrackers.removeValue(forKey: sessionID)
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

    func recordRetrievalHit(sessionID: UUID, frameID: UInt64, query: String, score: Float) {
        var sessionTrackers = recallTrackers[sessionID, default: [:]]
        var tracker = sessionTrackers[frameID, default: CompatRecallTracker()]
        tracker.recallCount += 1
        tracker.queryHashes.insert(WaxMCPTools.stableHash(query.lowercased()))
        tracker.lastRetrievedAtMs = max(tracker.lastRetrievedAtMs ?? 0, WaxMCPTools.nowMs())
        tracker.scoreTotal += score
        sessionTrackers[frameID] = tracker
        recallTrackers[sessionID] = sessionTrackers
    }

    func recallSignals(for sessionID: UUID) -> [UInt64: BrokerSessionRecallSignals] {
        let sessionTrackers = recallTrackers[sessionID, default: [:]]
        return sessionTrackers.reduce(into: [:]) { partial, entry in
            let tracker = entry.value
            partial[entry.key] = BrokerSessionRecallSignals(
                recallCount: tracker.recallCount,
                uniqueQueryCount: tracker.queryHashes.count,
                lastRetrievedAtMs: tracker.lastRetrievedAtMs,
                averageScore: tracker.recallCount > 0 ? (tracker.scoreTotal / Float(tracker.recallCount)) : 0
            )
        }
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
            if let migration = migratedName(for: params.name) {
                return errorResult(
                    message: "tool '\(params.name)' has been renamed to '\(migration)'",
                    code: "tool_renamed"
                )
            }
            let normalizedName = params.name
            try validateToolAvailability(name: normalizedName, structuredMemoryEnabled: structuredMemoryEnabled)
            try validateArgumentSurface(name: normalizedName, arguments: params.arguments)

            switch normalizedName {
            case "memory_append":
                return try await compatRemember(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "memory_search":
                return try await compatMemorySearch(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "memory_get":
                return try await compatMemoryGet(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "remember":
                return try await compatRemember(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "recall":
                return try await compatRecall(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "search":
                return try await compatSearch(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "session_synthesize":
                return try await compatSessionSynthesize(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "memory_promote":
                return try await compatMemoryPromote(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "promote":
                return try await compatPromote(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "memory_health":
                return try await compatMemoryHealth(memory)
            case "knowledge_capture":
                return try await compatKnowledgeCapture(params.arguments, memory: memory)
            case "corpus_search":
                return try await compatCorpusSearch(params.arguments, noEmbedder: noEmbedder, embedderChoice: embedderChoice)
            case "flush":
                return try await compatFlush(memory)
            case "stats":
                return try await compatStats(memory, sessionRegistry: sessionRegistry)
            case "session_start":
                return await compatSessionStart(sessionRegistry)
            case "session_resume":
                return try await compatSessionResume(params.arguments, sessionRegistry: sessionRegistry)
            case "session_end":
                return try await compatSessionEnd(params.arguments, sessionRegistry: sessionRegistry)
            case "handoff":
                return try await compatHandoff(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "handoff_latest":
                return try await compatHandoffLatest(params.arguments, memory: memory)
            case "compact_context":
                return try await compatCompactContext(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "markdown_export":
                return try await compatMarkdownExport(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "markdown_sync":
                return try await compatMarkdownSync(params.arguments, memory: memory, sessionRegistry: sessionRegistry)
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

        func optionalFloat(_ key: String) throws -> Float? {
            guard let value = try optionalDouble(key) else { return nil }
            return Float(value)
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

        func optionalValue(_ key: String) -> Value? {
            values[key]
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

    static func compatNormalizedMetadata(
        args: CompatArguments,
        metadata: [String: String],
        sessionID: UUID?
    ) throws -> [String: String] {
        let memoryType = try args.optionalString("memory_type").flatMap(MemoryType.init(rawValue:))
        if try args.optionalString("memory_type") != nil, memoryType == nil {
            throw ToolValidationError.invalid("memory_type must be one of: \(MemoryType.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let durability = try args.optionalString("durability").flatMap(MemoryDurability.init(rawValue:))
        if try args.optionalString("durability") != nil, durability == nil {
            throw ToolValidationError.invalid("durability must be one of: \(MemoryDurability.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return MemorySemantics.normalizeWriteMetadata(
            metadata: metadata,
            semantics: MemoryWriteSemantics(
                type: memoryType,
                durability: durability,
                project: try args.optionalString("project"),
                repo: try args.optionalString("repo"),
                confidence: try args.optionalFloat("confidence"),
                expiresInDays: try args.optionalInt("expires_in_days"),
                reviewed: try args.optionalBool("reviewed") ?? false,
                lock: try args.optionalBool("locked") ?? false
            ),
            sessionID: sessionID,
            inferredScope: MemorySemantics.inferScopeContext()
        )
    }

    static func compatValidateDurableWrite(content: String, metadata: [String: String]) throws {
        let semantics = MemorySemantics.parse(metadata: metadata)
        guard semantics.durability == .durable || semantics.durability == .locked else { return }
        if let detected = SecretHeuristics.detectSecretLikeContent(content, metadata: metadata) {
            throw ToolValidationError.invalid("Refusing to store durable memory containing secret-like content (\(detected))")
        }
    }

    static func compatDocument(
        for frameID: UInt64,
        in documentByFrameID: [UInt64: MemoryOrchestrator.CorpusSourceDocument],
        memory: MemoryOrchestrator
    ) async throws -> MemoryOrchestrator.CorpusSourceDocument? {
        if let document = documentByFrameID[frameID] {
            return document
        }
        let canonicalFrameID = try await memory.canonicalDocumentFrameID(for: frameID)
        return documentByFrameID[canonicalFrameID]
    }

    static func compatResolveSessionID(_ explicit: UUID?, sessionRegistry: CompatSessionRegistry) async throws -> UUID? {
        if let explicit { return explicit }
        let active = await sessionRegistry.activeSessionIDs().sorted { $0.uuidString < $1.uuidString }
        return active.count == 1 ? active.first : nil
    }

    static func compatPromotionProposalValue(_ proposal: BrokerPromotionProposal) -> Value {
        [
            "content": .string(proposal.content),
            "summary": .string(proposal.summary),
            "suggested_type": .string(proposal.suggestedType.rawValue),
            "suggested_durability": .string(proposal.suggestedDurability.rawValue),
            "confidence": .double(Double(proposal.confidence)),
            "recall_count": .int(proposal.recallCount),
            "unique_query_count": .int(proposal.uniqueQueryCount),
            "last_retrieved_at_ms": proposal.lastRetrievedAtMs.map { .int(Int($0)) } ?? .null,
            "average_relevance_score": .double(Double(proposal.averageRelevanceScore)),
            "should_write": .bool(proposal.shouldWrite),
            "reasons": .array(proposal.reasons.map(Value.string)),
            "duplicate_matches": .array(proposal.duplicateMatches.map { duplicate in
                [
                    "frame_id": .int(Int(duplicate.frameId)),
                    "similarity": .double(Double(duplicate.similarity)),
                    "summary": .string(duplicate.summary),
                    "memory_type": .string(duplicate.memoryType.rawValue),
                ]
            }),
        ]
    }

    static func compatParseSearchFilters(_ args: CompatArguments) throws -> CompatParsedFilters {
        let sessionID = try compatParseSessionID(args)
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
                throw ToolValidationError.invalid("unsupported filter key(s): \(names)")
            }

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
            if let includeRaw = filters["include_deleted"] {
                guard case .bool(let value) = includeRaw else {
                    throw ToolValidationError.invalid("filters.include_deleted must be a boolean")
                }
                includeDeleted = value
            }
            if let includeRaw = filters["include_superseded"] {
                guard case .bool(let value) = includeRaw else {
                    throw ToolValidationError.invalid("filters.include_superseded must be a boolean")
                }
                includeSuperseded = value
            }
            if let includeRaw = filters["include_surrogates"] {
                guard case .bool(let value) = includeRaw else {
                    throw ToolValidationError.invalid("filters.include_surrogates must be a boolean")
                }
                includeSurrogates = value
            }
            if let frameIdsRaw = filters["frame_ids"] {
                guard case .array(let rawFrameIds) = frameIdsRaw else {
                    throw ToolValidationError.invalid("filters.frame_ids must be an array of non-negative integers")
                }
                var parsedFrameIds = Set<UInt64>()
                parsedFrameIds.reserveCapacity(rawFrameIds.count)
                for value in rawFrameIds {
                    guard case .int(let raw) = value, raw >= 0 else {
                        throw ToolValidationError.invalid("filters.frame_ids must contain only non-negative integers")
                    }
                    parsedFrameIds.insert(UInt64(raw))
                }
                frameIds = parsedFrameIds
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
        let frameFilter: FrameFilter? = (metadataFilter != nil || includeDeleted || includeSuperseded || includeSurrogates || frameIds != nil)
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
                "include_deleted": .bool(includeDeleted),
                "include_superseded": .bool(includeSuperseded),
                "include_surrogates": .bool(includeSurrogates),
                "frame_ids": .array((frameIds ?? []).sorted().map { .int(Int($0)) }),
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
        let rawMetadata = try compatCoerceMetadata(try args.optionalObject("metadata"))
        var metadata = rawMetadata
        if metadata["session_id"] != nil {
            throw ToolValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        metadata = try compatNormalizedMetadata(args: args, metadata: metadata, sessionID: sessionID)
        try compatValidateDurableWrite(content: content, metadata: metadata)
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
        let directMode = try compatSearchMode(
            modeRaw: try args.optionalString("mode") ?? "hybrid",
            alpha: try args.optionalDouble("alpha")
        )
        let embeddingPolicy = compatEmbeddingPolicy(for: directMode)
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
                "explanations": .array(item.explanations.map(Value.string)),
            ]
        }
        if let sessionID = filters.sessionID {
            for item in selected {
                await sessionRegistry.recordRetrievalHit(
                    sessionID: sessionID,
                    frameID: item.frameId,
                    query: query,
                    score: item.score
                )
            }
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
        let mode = try compatSearchMode(
            modeRaw: try args.optionalString("mode") ?? "text",
            alpha: try args.optionalDouble("alpha")
        )
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
                "explanations": .array(hit.explanations.map(Value.string)),
            ]
        }
        if let sessionID = filters.sessionID {
            for hit in execution.hits {
                await sessionRegistry.recordRetrievalHit(
                    sessionID: sessionID,
                    frameID: hit.frameId,
                    query: query,
                    score: hit.score
                )
            }
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

    static func compatMemorySearch(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let query = try args.requiredString("query")
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...200).contains(topK) else {
            throw ToolValidationError.invalid("topK must be between 1 and 200")
        }
        let sessionID = try compatParseSessionID(args)
        try await compatValidateActiveSession(sessionID, in: sessionRegistry)
        let includeWorking = try args.optionalBool("include_working") ?? true
        let includeEpisodic = try args.optionalBool("include_episodic") ?? true
        let includeDurable = try args.optionalBool("include_durable") ?? true
        let mode = try compatSearchMode(
            modeRaw: try args.optionalString("mode") ?? "text",
            alpha: try args.optionalDouble("alpha")
        )

        let candidateTopK = compatPostFilterCandidateLimit(for: topK)
        let execution = try await memory.searchExecution(
            query: query,
            mode: mode,
            topK: candidateTopK,
            frameFilter: nil,
            timeRange: nil
        )
        let documents = try await memory.corpusSourceDocuments()
        let documentByFrameID = Dictionary(uniqueKeysWithValues: documents.map { ($0.frameId, $0) })
        let activeSessionIDs = Set(await sessionRegistry.activeSessionIDs().map(\.uuidString))

        var results: [Value] = []
        var workingHitsToRecord: [(frameID: UInt64, score: Float)] = []
        for hit in execution.hits {
            guard let document = try await compatDocument(
                for: hit.frameId,
                in: documentByFrameID,
                memory: memory
            ) else { continue }
            let documentSessionID = document.metadata["session_id"]
            let horizon: String
            let memoryID: String

            if let documentSessionID {
                if activeSessionIDs.contains(documentSessionID) {
                    guard includeWorking else { continue }
                    horizon = "working"
                } else {
                    guard includeEpisodic else { continue }
                    horizon = "episodic"
                }
                memoryID = "\(horizon):\(documentSessionID):\(document.frameId)"
            } else {
                guard includeDurable else { continue }
                horizon = "durable"
                memoryID = "durable:\(document.frameId)"
            }

            if let sessionID, horizon == "working", documentSessionID != sessionID.uuidString {
                continue
            }
            if let sessionID, horizon == "working", documentSessionID == sessionID.uuidString {
                workingHitsToRecord.append((frameID: document.frameId, score: hit.score))
            }

            results.append([
                "memory_id": .string(memoryID),
                "horizon": .string(horizon),
                "frame_id": .int(Int(document.frameId)),
                "score": .double(Double(hit.score)),
                "preview": .string(hit.previewText ?? document.text),
                "text": .string(document.text),
                "metadata": .object(document.metadata.mapValues(Value.string)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "explanations": .array(hit.explanations.map(Value.string)),
            ])
            if results.count == topK {
                break
            }
        }
        if let sessionID {
            for hit in workingHitsToRecord {
                await sessionRegistry.recordRetrievalHit(
                    sessionID: sessionID,
                    frameID: hit.frameID,
                    query: query,
                    score: hit.score
                )
            }
        }

        let displayText = results.isEmpty ? "No results." : results.compactMap(encodeJSON).joined(separator: "\n")
        return textWithJSONResourceResult(
            text: displayText,
            payload: [
                "query": .string(query),
                "session_id": sessionID.map { .string($0.uuidString) } ?? .null,
                "topK": .int(topK),
                "requested_mode": .string(execution.requestedModeSummary),
                "effective_mode": .string(execution.effectiveModeSummary),
                "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
                "include_working": .bool(includeWorking),
                "include_episodic": .bool(includeEpisodic),
                "include_durable": .bool(includeDurable),
                "results": .array(results),
            ],
            uri: "wax://tool/memory-search-summary"
        )
    }

    static func compatPostFilterCandidateLimit(for topK: Int) -> Int {
        min(1_000, max(topK * 5, topK + 200))
    }

    static func compatMemoryGet(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let memoryID = try args.requiredString("memory_id")
        let parts = memoryID.split(separator: ":").map(String.init)
        guard parts.count >= 2 else {
            throw ToolValidationError.invalid("memory_id must be in the form '<horizon>:<frame>' or '<horizon>:<session_id>:<frame>'")
        }
        let documents = try await memory.corpusSourceDocuments()
        let document: MemoryOrchestrator.CorpusSourceDocument
        let horizon = parts[0]
        switch horizon {
        case "durable":
            guard parts.count == 2, let frameID = UInt64(parts[1]),
                  let match = documents.first(where: { $0.frameId == frameID && $0.metadata["session_id"] == nil }) else {
                throw ToolValidationError.invalid("Unknown durable memory_id")
            }
            document = match
        case "working", "episodic":
            guard parts.count == 3,
                  let sessionID = UUID(uuidString: parts[1]),
                  let frameID = UInt64(parts[2]) else {
                throw ToolValidationError.invalid("Unknown session memory_id")
            }
            if horizon == "working" {
                try await compatValidateActiveSession(sessionID, in: sessionRegistry)
            }
            guard let match = documents.first(where: {
                $0.frameId == frameID && $0.metadata["session_id"] == sessionID.uuidString
            }) else {
                throw ToolValidationError.invalid("Unknown session memory_id")
            }
            document = match
        default:
            throw ToolValidationError.invalid("memory_id horizon must be one of: working, episodic, durable")
        }
        return textWithJSONResourceResult(
            text: document.text,
            payload: [
                "memory_id": .string(memoryID),
                "text": .string(document.text),
                "metadata": .object(document.metadata.mapValues(Value.string)),
                "frame_id": .int(Int(document.frameId)),
            ],
            uri: "wax://tool/memory-get-summary"
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

    static func compatPromote(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        var normalized = arguments ?? [:]
        if normalized["approve"] == nil {
            normalized["approve"] = .bool(true)
        }
        return try await compatMemoryPromote(normalized, memory: memory, sessionRegistry: sessionRegistry)
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

    static func compatSessionSynthesize(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let sessionID = try await compatResolveSessionID(try compatParseSessionID(args), sessionRegistry: sessionRegistry)
        guard let sessionID else {
            throw ToolValidationError.invalid("session_id is required when no active session is available")
        }
        let documents = try await memory.corpusSourceDocuments().filter { $0.metadata["session_id"] == sessionID.uuidString }
        let longTermDocuments = try await memory.corpusSourceDocuments().filter { $0.metadata["session_id"] == nil }
        let recallSignals = await sessionRegistry.recallSignals(for: sessionID)
        let synthesis = BrokerMemoryInsights.synthesizeSession(
            documents: documents,
            scope: MemorySemantics.inferScopeContext(),
            longTermDocuments: longTermDocuments,
            recallSignalsByFrameID: recallSignals
        )
        return textWithJSONResourceResult(
            text: synthesis.summary,
            payload: [
                "session_id": .string(sessionID.uuidString),
                "summary": .string(synthesis.summary),
                "handoff": .string(synthesis.handoff),
                "lessons": .array(synthesis.lessons.map(Value.string)),
                "decisions": .array(synthesis.decisions.map(Value.string)),
                "preferences": .array(synthesis.preferences.map(Value.string)),
                "constraints": .array(synthesis.constraints.map(Value.string)),
                "durable_candidates": .array(synthesis.durableCandidates.map(compatPromotionProposalValue)),
            ],
            uri: "wax://tool/session-synthesize-summary"
        )
    }

    static func compatMemoryPromote(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let sessionID = try await compatResolveSessionID(try compatParseSessionID(args), sessionRegistry: sessionRegistry)
        let explicitContent = try args.optionalString("content")
        let frameID = try args.optionalInt("frame_id").map(UInt64.init)
        let approve = try args.optionalBool("approve") ?? false

        var sourceMetadata: [String: String] = [:]
        let content: String
        if let explicitContent, !explicitContent.isEmpty {
            content = explicitContent
        } else {
            guard let sessionID else {
                throw ToolValidationError.invalid("Provide content or an active session_id for promotion")
            }
            let documents = try await memory.corpusSourceDocuments()
                .filter { $0.metadata["session_id"] == sessionID.uuidString }
            let document = if let frameID {
                documents.first { $0.frameId == frameID }
            } else {
                documents.sorted { $0.timestampMs > $1.timestampMs }.first
            }
            guard let document else {
                throw ToolValidationError.invalid("No promotable session memory was found")
            }
            content = document.text
            sourceMetadata = document.metadata
        }

        var metadata = try compatCoerceMetadata(try args.optionalObject("metadata")).merging(sourceMetadata) { current, _ in current }
        metadata = try compatNormalizedMetadata(args: args, metadata: metadata, sessionID: nil)
        if let sessionID {
            metadata[MemoryMetadataKeys.promotedFromSession] = sessionID.uuidString
            metadata.removeValue(forKey: "session_id")
        }
        if let frameID {
            metadata[MemoryMetadataKeys.promotedFromFrame] = String(frameID)
        }

        let longTermDocuments = try await memory.corpusSourceDocuments().filter { $0.metadata["session_id"] == nil }
        let recallSignalsByFrameID: [UInt64: BrokerSessionRecallSignals] = if let sessionID {
            await sessionRegistry.recallSignals(for: sessionID)
        } else {
            [:]
        }
        let proposal = BrokerMemoryInsights.proposePromotion(
            content: content,
            metadata: metadata,
            sessionID: sessionID,
            sourceFrameID: frameID,
            scope: MemorySemantics.inferScopeContext(),
            longTermDocuments: longTermDocuments,
            recallSignals: frameID.flatMap { recallSignalsByFrameID[$0] }
        )
        if approve, proposal.shouldWrite {
            let writeSemantics = MemoryWriteSemantics(
                type: try args.optionalString("memory_type").flatMap(MemoryType.init(rawValue:)),
                durability: try args.optionalString("durability").flatMap(MemoryDurability.init(rawValue:)),
                project: try args.optionalString("project"),
                repo: try args.optionalString("repo"),
                confidence: try args.optionalFloat("confidence"),
                expiresInDays: try args.optionalInt("expires_in_days"),
                reviewed: try args.optionalBool("reviewed") ?? false,
                lock: try args.optionalBool("locked") ?? false
            )
            metadata = MemorySemantics.approvedPromotionMetadata(
                metadata: metadata,
                semantics: writeSemantics,
                suggestedType: proposal.suggestedType,
                suggestedDurability: proposal.suggestedDurability,
                suggestedConfidence: proposal.confidence
            )
            try compatValidateDurableWrite(content: content, metadata: metadata)
            try await memory.remember(content, metadata: metadata)
            try await memory.flush()
        }
        return jsonResult([
            "approved": .bool(approve),
            "written": .bool(approve && proposal.shouldWrite),
            "proposal": compatPromotionProposalValue(proposal),
            "metadata": .object(metadata.mapValues(Value.string)),
        ])
    }

    static func compatMemoryHealth(_ memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let documents = try await memory.corpusSourceDocuments()
        let accessStats = await memory.accessStatsSnapshot()
        let facts = try? await memory.facts(limit: 500)
        let report = BrokerMemoryInsights.healthReport(documents: documents, accessStats: accessStats, facts: facts)
        return textWithJSONResourceResult(
            text: "Health: \(report.totalDocuments) docs, \(report.duplicatePairs.count) duplicate pairs.",
            payload: [
                "total_documents": .int(report.totalDocuments),
                "typed_counts": .object(report.typedCounts.mapValues(Value.int)),
                "expired_frame_ids": .array(report.expiredFrameIds.map { .int(Int($0)) }),
                "stale_frame_ids": .array(report.staleFrameIds.map { .int(Int($0)) }),
                "low_hit_frame_ids": .array(report.lowHitFrameIds.map { .int(Int($0)) }),
                "duplicate_pairs": .array(report.duplicatePairs.map { pair in
                    [
                        "left_frame_id": .int(Int(pair.leftFrameId)),
                        "right_frame_id": .int(Int(pair.rightFrameId)),
                        "similarity": .double(Double(pair.similarity)),
                    ]
                }),
                "contradictions": .array(report.contradictionSummaries.map(Value.string)),
            ],
            uri: "wax://tool/memory-health-summary"
        )
    }

    static func compatKnowledgeCapture(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let content = try args.requiredString("content")
        let durability = try args.optionalString("durability")
        let locked = try args.optionalBool("locked") ?? false
        var normalizedArguments = arguments ?? [:]
        if durability == nil, !locked {
            normalizedArguments["durability"] = .string(MemoryDurability.durable.rawValue)
        }
        let normalizedArgs = CompatArguments(normalizedArguments)
        let metadata = try compatNormalizedMetadata(
            args: normalizedArgs,
            metadata: try compatCoerceMetadata(try args.optionalObject("metadata")),
            sessionID: nil
        )
        try compatValidateDurableWrite(content: content, metadata: metadata)
        if let subject = try args.optionalString("subject"),
           let kind = try args.optionalString("kind") {
            _ = try await memory.upsertEntity(key: EntityKey(subject), kind: kind, aliases: try args.optionalStringArray("aliases") ?? [], commit: true)
        }
        if let subject = try args.optionalString("subject"),
           let predicate = try args.optionalString("predicate"),
           let object = args.optionalValue("object") {
            _ = try await memory.assertFact(
                subject: EntityKey(subject),
                predicate: PredicateKey(predicate),
                object: try compatFactValue(object),
                relation: .sets,
                validFromMs: nil,
                validToMs: nil,
                commit: true
            )
        }
        try await memory.remember(content, metadata: metadata)
        try await memory.flush()
        return jsonResult([
            "status": .string("ok"),
            "memory_type": .string(metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue),
            "durability": .string(metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue),
        ])
    }

    static func compatSessionStart(_ sessionRegistry: CompatSessionRegistry) async -> CallTool.Result {
        let value = await sessionRegistry.start()
        return jsonResult([
            "status": .string("ok"),
            "session_id": .string(value.uuidString),
        ])
    }

    static func compatSessionResume(_ arguments: [String: Value]?, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        guard let sessionID = try compatParseSessionID(args) else {
            throw ToolValidationError.invalid("session_id is required in compatibility mode")
        }
        try await compatValidateActiveSession(sessionID, in: sessionRegistry)
        return jsonResult([
            "status": .string("ok"),
            "session_id": .string(sessionID.uuidString),
            "resumed": .bool(true),
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

    static func compatCompactContext(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let sessionID = try await compatResolveSessionID(try compatParseSessionID(args), sessionRegistry: sessionRegistry)
        try await compatValidateActiveSession(sessionID, in: sessionRegistry)
        let query = try args.requiredString("query")
        let limit = min(try args.optionalInt("max_items") ?? 6, 12)
        let mode = try compatSearchMode(
            modeRaw: try args.optionalString("mode") ?? "hybrid",
            alpha: try args.optionalDouble("alpha")
        )
        let frameFilter = sessionID.map {
            FrameFilter(metadataFilter: MetadataFilter(requiredEntries: ["session_id": $0.uuidString]))
        }
        let execution = try await memory.recallExecution(
            query: query,
            embeddingPolicy: compatEmbeddingPolicy(for: mode),
            frameFilter: frameFilter,
            timeRange: nil,
            topK: limit,
            mode: mode
        )
        let documents = try await memory.corpusSourceDocuments()
        let documentByFrameID = Dictionary(uniqueKeysWithValues: documents.map { ($0.frameId, $0) })
        let activeSessionIDs = Set(await sessionRegistry.activeSessionIDs().map(\.uuidString))
        var encodedItems: [Value] = []
        var itemTexts: [String] = []
        for item in execution.context.items.prefix(limit) {
            guard let document = try await compatDocument(
                for: item.frameId,
                in: documentByFrameID,
                memory: memory
            ) else { continue }
            let documentSessionID = document.metadata["session_id"]
            let horizon: String
            let memoryID: String
            if let documentSessionID {
                let isWorking = activeSessionIDs.contains(documentSessionID)
                horizon = isWorking ? "working" : "episodic"
                memoryID = "\(horizon):\(documentSessionID):\(document.frameId)"
            } else {
                horizon = "durable"
                memoryID = "durable:\(document.frameId)"
            }
            itemTexts.append(item.text)
            encodedItems.append([
                "memory_id": .string(memoryID),
                "horizon": .string(horizon),
                "frame_id": .int(Int(document.frameId)),
                "preview": .string(item.text),
            ])
        }
        let compactedText = itemTexts.enumerated().map { index, text in
            "\(index + 1). \(text)"
        }.joined(separator: "\n")
        return textWithJSONResourceResult(
            text: compactedText,
            payload: [
                "query": .string(query),
                "session_id": sessionID.map { .string($0.uuidString) } ?? .null,
                "used_tokens": .int(execution.context.totalTokens),
                "summary": .string(itemTexts.first ?? "No compacted context available."),
                "short_context": .array(encodedItems),
                "medium_context": .array([]),
                "long_context": .array([]),
                "compacted_text": .string(compactedText),
            ],
            uri: "wax://tool/compact-context-summary"
        )
    }

    static func compatMarkdownExport(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry _: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let outputDir = try args.requiredString("output_dir")
        let outputURL = URL(fileURLWithPath: outputDir, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let memoryDir = outputURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let documents = try await memory.corpusSourceDocuments().filter { $0.metadata["session_id"] == nil }
        let lines = ["# MEMORY", ""] + documents.map { document in
            let marker = MarkdownProjectionMarker(
                managed: true,
                sourceKind: MarkdownProjectionKind.memory.rawValue,
                frameID: document.frameId,
                memoryID: "durable:\(document.frameId)",
                hash: stableHash(document.text)
            )
            return "- \(document.text) \(BrokerMarkdownSync.markerComment(marker))"
        }
        let memoryURL = outputURL.appendingPathComponent("MEMORY.md")
        try lines.joined(separator: "\n").write(to: memoryURL, atomically: true, encoding: .utf8)
        return jsonResult([
            "status": .string("ok"),
            "output_dir": .string(outputURL.path),
            "memory_md_path": .string(memoryURL.path),
            "daily_note_paths": .array([]),
            "dreams_path": .null,
            "handoff_summary_path": .null,
        ])
    }

    static func compatMarkdownSync(_ arguments: [String: Value]?, memory: MemoryOrchestrator, sessionRegistry _: CompatSessionRegistry) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let rootDir = try args.requiredString("root_dir")
        let dryRun = try args.optionalBool("dry_run") ?? false
        let rootURL = URL(fileURLWithPath: rootDir, isDirectory: true).standardizedFileURL
        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        let dreamsURL = rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("DREAMS.md")
        var created = 0
        var approvedDreams = 0

        for entry in try BrokerMarkdownSync.parseFile(at: memoryURL) where entry.isManagedImportCandidate {
            var semantics = MemoryWriteSemantics(type: .fact, durability: .durable, reviewed: true)
            if let section = entry.section, let type = MemoryType(rawValue: section.lowercased()) {
                semantics.type = type
            }
            let metadata = MemorySemantics.normalizeWriteMetadata(
                metadata: [
                    MemoryMetadataKeys.sourcePath: memoryURL.path,
                    MemoryMetadataKeys.sourceLine: String(entry.lineNumber),
                    MemoryMetadataKeys.sourceHash: stableHash(entry.text),
                    MemoryMetadataKeys.sourceKind: MarkdownProjectionKind.memory.rawValue,
                    MemoryMetadataKeys.sourceManaged: "true",
                ],
                semantics: semantics,
                sessionID: nil,
                inferredScope: nil
            )
            if !dryRun {
                try await memory.remember(entry.text, metadata: metadata)
            }
            created += 1
        }

        for entry in try BrokerMarkdownSync.parseFile(at: dreamsURL) where entry.checked == true {
            let metadata = MemorySemantics.normalizeWriteMetadata(
                metadata: [:],
                semantics: MemoryWriteSemantics(type: .decision, durability: .durable, reviewed: true),
                sessionID: nil,
                inferredScope: nil
            )
            if !dryRun {
                try await memory.remember(entry.text, metadata: metadata)
            }
            approvedDreams += 1
        }

        if !dryRun {
            try await memory.flush()
        }
        return jsonResult([
            "status": .string("ok"),
            "dry_run": .bool(dryRun),
            "root_dir": .string(rootURL.path),
            "memory_md_path": FileManager.default.fileExists(atPath: memoryURL.path) ? .string(memoryURL.path) : .null,
            "daily_note_paths": .array([]),
            "dreams_path": FileManager.default.fileExists(atPath: dreamsURL.path) ? .string(dreamsURL.path) : .null,
            "counts": [
                "created": .int(created),
                "updated": .int(0),
                "deleted": .int(0),
                "unchanged": .int(0),
                "approved_dreams": .int(approvedDreams),
                "rejected_dreams": .int(0),
            ],
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
        let evidence = try compatStructuredEvidence(args.optionalValue("evidence"))
        let factID = try await memory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: object,
            relation: relation,
            validFromMs: try args.optionalInt64("valid_from"),
            validToMs: try args.optionalInt64("valid_to"),
            evidence: evidence,
            commit: true
        )
        return jsonResult([
            "status": .string("ok"),
            "fact_id": .int(Int(factID.rawValue)),
            "evidence_count": .int(evidence.count),
            "committed": .bool(true),
        ])
    }

    static func compatFactRetract(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let factID = try args.optionalInt("fact_id") ?? 0
        let atMs = try args.optionalInt64("at_ms")
        try await memory.retractFact(factId: FactRowID(rawValue: Int64(factID)), atMs: atMs, commit: true)
        return jsonResult([
            "status": .string("ok"),
            "fact_id": .int(factID),
            "at_ms": atMs.map { .int(Int($0)) } ?? .null,
            "committed": .bool(true),
        ])
    }

    static func compatFactsQuery(_ arguments: [String: Value]?, memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let args = CompatArguments(arguments)
        let limit = try args.optionalInt("limit") ?? 20
        let asOfMs = try args.optionalInt64("as_of") ?? Int64.max
        let result = try await memory.facts(
            about: try args.optionalString("subject").map { EntityKey($0) },
            predicate: try args.optionalString("predicate").map { PredicateKey($0) },
            asOfMs: asOfMs,
            limit: limit
        )
        return jsonResult([
            "count": .int(result.hits.count),
            "truncated": .bool(result.wasTruncated),
            "as_of": .int(Int(asOfMs)),
            "hits": .array(result.hits.map { hit in
                [
                    "fact_id": .int(Int(hit.factId.rawValue)),
                    "subject": .string(hit.fact.subject.rawValue),
                    "predicate": .string(hit.fact.predicate.rawValue),
                    "object": compatFactValuePayload(hit.fact.object),
                    "evidence_count": .int(hit.evidence.count),
                    "evidence": .array(hit.evidence.map(compatStructuredEvidencePayload)),
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
        let mode = try compatSearchMode(
            modeRaw: try args.optionalString("mode") ?? "text",
            alpha: try args.optionalDouble("alpha")
        )
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...200).contains(topK) else {
            throw ToolValidationError.invalid("topK must be between 1 and 200")
        }
        let corpusNoEmbedder = mode == .text ? true : noEmbedder
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
                mode: mode,
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
                "stores_skipped": .int(summary.storesSkipped),
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
            if object.count == 2,
               case .string(let type)? = object["type"],
               let genericValue = object["value"] {
                switch type {
                case "entity":
                    guard case .string(let raw) = genericValue else {
                        throw ToolValidationError.invalid("entity typed object value must be a string")
                    }
                    return .entity(EntityKey(raw))
                case "time_ms":
                    guard case .int(let raw) = genericValue else {
                        throw ToolValidationError.invalid("time_ms typed object value must be an integer")
                    }
                    return .timeMs(Int64(raw))
                case "data_base64":
                    guard case .string(let raw) = genericValue, let decoded = Data(base64Encoded: raw) else {
                        throw ToolValidationError.invalid("data_base64 typed object value must be a base64 string")
                    }
                    return .data(decoded)
                default:
                    throw ToolValidationError.invalid("typed object type must be one of: entity, time_ms, data_base64")
                }
            }
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

    static func compatStructuredEvidence(_ value: Value?) throws -> [StructuredEvidence] {
        guard let value else { return [] }
        guard case .array(let array) = value else {
            throw ToolValidationError.invalid("evidence must be an array")
        }
        return try array.map { item in
            guard case .object(let object) = item else {
                throw ToolValidationError.invalid("evidence must contain only objects")
            }
            let allowedKeys: Set<String> = [
                "source_frame_id",
                "chunk_index",
                "span_start_utf8",
                "span_end_utf8",
                "extractor_id",
                "extractor_version",
                "confidence",
                "asserted_at_ms",
            ]
            let unknownKeys = Set(object.keys).subtracting(allowedKeys)
            guard unknownKeys.isEmpty else {
                throw ToolValidationError.invalid("unknown evidence fields: \(unknownKeys.sorted().joined(separator: ", "))")
            }
            guard case .int(let sourceRaw)? = object["source_frame_id"], sourceRaw >= 0 else {
                throw ToolValidationError.invalid("evidence.source_frame_id must be a non-negative integer")
            }
            let chunkIndex: UInt32? = try {
                guard let value = object["chunk_index"] else { return nil }
                guard case .int(let raw) = value, raw >= 0, raw <= Int(UInt32.max) else {
                    throw ToolValidationError.invalid("evidence.chunk_index must be a non-negative integer")
                }
                return UInt32(raw)
            }()
            let span = try compatEvidenceSpan(object)
            let extractorId = try compatRequiredEvidenceString(object, key: "extractor_id")
            let extractorVersion = try compatRequiredEvidenceString(object, key: "extractor_version")
            let confidence = try compatEvidenceConfidence(object["confidence"])
            guard case .int(let assertedAtMs)? = object["asserted_at_ms"] else {
                throw ToolValidationError.invalid("evidence.asserted_at_ms must be an integer")
            }
            return StructuredEvidence(
                sourceFrameId: UInt64(sourceRaw),
                chunkIndex: chunkIndex,
                spanUTF8: span,
                extractorId: extractorId,
                extractorVersion: extractorVersion,
                confidence: confidence,
                assertedAtMs: Int64(assertedAtMs)
            )
        }
    }

    static func compatEvidenceSpan(_ object: [String: Value]) throws -> Range<Int>? {
        guard object["span_start_utf8"] != nil || object["span_end_utf8"] != nil else {
            return nil
        }
        guard case .int(let start)? = object["span_start_utf8"],
              case .int(let end)? = object["span_end_utf8"],
              start >= 0, end > start else {
            throw ToolValidationError.invalid("evidence span must include non-negative span_start_utf8 and greater span_end_utf8")
        }
        return start..<end
    }

    static func compatRequiredEvidenceString(_ object: [String: Value], key: String) throws -> String {
        guard case .string(let raw)? = object[key] else {
            throw ToolValidationError.invalid("evidence.\(key) must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolValidationError.invalid("evidence.\(key) must not be empty")
        }
        return trimmed
    }

    static func compatEvidenceConfidence(_ value: Value?) throws -> Double? {
        guard let value else { return nil }
        let confidence: Double
        switch value {
        case .double(let raw):
            confidence = raw
        case .int(let raw):
            confidence = Double(raw)
        default:
            throw ToolValidationError.invalid("evidence.confidence must be a finite number between 0 and 1")
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw ToolValidationError.invalid("evidence.confidence must be a finite number between 0 and 1")
        }
        return confidence
    }

    static func compatStructuredEvidencePayload(_ evidence: StructuredEvidence) -> Value {
        var object: [String: Value] = [
            "source_frame_id": .int(Int(evidence.sourceFrameId)),
            "extractor_id": .string(evidence.extractorId),
            "extractor_version": .string(evidence.extractorVersion),
            "asserted_at_ms": .int(Int(evidence.assertedAtMs)),
        ]
        object["chunk_index"] = evidence.chunkIndex.map { .int(Int($0)) } ?? .null
        object["span_start_utf8"] = evidence.spanUTF8.map { .int($0.lowerBound) } ?? .null
        object["span_end_utf8"] = evidence.spanUTF8.map { .int($0.upperBound) } ?? .null
        object["confidence"] = evidence.confidence.map { .double($0) } ?? .null
        return .object(object)
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

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
#endif
