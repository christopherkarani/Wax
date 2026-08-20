#if MCPServer
import Foundation
import MCP
import Wax
import WaxCore

enum WaxMCPTools {
    static func register(
        on server: Server,
        brokerConfiguration: AgentBrokerConfiguration,
        structuredMemoryEnabled: Bool
    ) async {
        let sessionHint = MCPClientSessionHint()
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
                sessionHint: sessionHint
            )
        }
    }

    static func handleCall(
        params: CallTool.Parameters,
        brokerConfiguration: AgentBrokerConfiguration,
        structuredMemoryEnabled: Bool = true,
        sessionHint: MCPClientSessionHint? = nil
    ) async -> CallTool.Result {
        await executeCall(
            params: params,
            structuredMemoryEnabled: structuredMemoryEnabled,
            sessionHint: sessionHint
        ) { request in
            try await AgentBrokerClient.perform(
                request: request,
                configuration: brokerConfiguration
            )
        }
    }

    /// In-process adapter over `AgentBrokerService.handle`. Tests use this so MCP
    /// JSON mapping is exercised without a second remember/recall implementation.
    static func handleCall(
        params: CallTool.Parameters,
        broker: AgentBrokerService,
        structuredMemoryEnabled: Bool = true
    ) async -> CallTool.Result {
        await executeCall(
            params: params,
            structuredMemoryEnabled: structuredMemoryEnabled,
            sessionHint: nil
        ) { request in
            await broker.handle(request)
        }
    }

    private static func executeCall(
        params: CallTool.Parameters,
        structuredMemoryEnabled: Bool,
        sessionHint: MCPClientSessionHint?,
        perform: (AgentBrokerRequest) async throws -> AgentBrokerResponse
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

            var forwarded = params.arguments ?? [:]
            if let oversize = contentLimitError(name: params.name, arguments: forwarded) {
                return oversize
            }
            injectClientCWDIfNeeded(name: params.name, arguments: &forwarded)
            injectClientSessionIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
            let verbosity = compactVerbosity(from: forwarded)

            let response = try await perform(
                AgentBrokerRequest(
                    command: params.name,
                    arguments: forwarded.mapValues(brokerValue(from:))
                )
            )

            guard response.ok else {
                if let payload = response.payload?.objectValue,
                   let code = payload["code"]?.stringValue {
                    let message = response.error
                        ?? payload["reason"]?.stringValue
                        ?? "Broker execution failed"
                    return structuredErrorResult(
                        message: message,
                        code: code,
                        fields: payload
                    )
                }
                let message = response.error ?? "Broker execution failed"
                return errorResult(message: message, code: errorCode(for: message))
            }

            guard let payload = response.payload else {
                return errorResult(message: "Broker returned an empty payload", code: "execution_failed")
            }
            sessionHint?.remember(name: params.name, payload: payload)
            return renderResult(name: params.name, payload: payload, verbosity: verbosity)
        } catch let error as ToolValidationError {
            return errorResult(message: error.localizedDescription, code: "invalid_arguments")
        } catch {
            return errorResult(message: error.localizedDescription, code: "execution_failed")
        }
    }
}

/// Per MCP `Server` session id. HTTP creates one Server per client session; stdio has one Server.
final class MCPClientSessionHint: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionID: String?

    func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    func remember(name: String, payload: AgentBrokerValue) {
        switch name {
        case "session_start", "session_resume", "session_open":
            if let sessionID = payload.objectValue?["session_id"]?.stringValue {
                lock.lock()
                self.sessionID = sessionID
                lock.unlock()
            }
        case "session_end", "session_close":
            if let ended = payload.objectValue?["session_id"]?.stringValue {
                lock.lock()
                if sessionID == ended {
                    sessionID = nil
                }
                lock.unlock()
            }
        default:
            break
        }
    }
}

private extension WaxMCPTools {
    static let readOnlyTextCommands: Set<String> = ["recall", "search", "memory_search", "memory_get", "compact_context", "corpus_search", "session_synthesize", "memory_health"]
    static let structuredCommands: Set<String> = ["knowledge_capture", "entity_upsert", "fact_assert", "fact_retract", "facts_query", "entity_resolve"]
    static let clientCWDCommands: Set<String> = [
        "session_start", "session_open", "remember", "memory_append", "knowledge_capture",
        "markdown_export", "recall",
    ]

    static func contentLimitError(name: String, arguments: [String: Value]) -> CallTool.Result? {
        guard case .string(let content)? = arguments["content"] else { return nil }
        let maxBytes = AgentBrokerService.maxContentBytes
        guard content.utf8.count > maxBytes else { return nil }
        return errorResult(
            message: "content exceeds \(maxBytes) bytes",
            code: "invalid_arguments"
        )
    }

    static func compactVerbosity(from arguments: [String: Value]) -> String? {
        guard case .string(let raw)? = arguments["verbosity"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func injectClientCWDIfNeeded(name: String, arguments: inout [String: Value]) {
        guard clientCWDCommands.contains(name), arguments["cwd"] == nil else { return }
        arguments["cwd"] = .string(FileManager.default.currentDirectoryPath)
    }

    static func injectClientSessionIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?
    ) {
        guard name == "stats", arguments["session_id"] == nil else { return }
        if let sessionID = sessionHint?.current() {
            arguments["session_id"] = .string(sessionID)
        }
    }

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
        case "wax_session_close": return "session_close"
        case "wax_session_open": return "session_open"
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

    static func renderResult(
        name: String,
        payload: AgentBrokerValue,
        verbosity: String? = nil
    ) -> CallTool.Result {
        let mcpPayload = mcpValue(from: removingDisplayText(from: payload))
        if verbosity == "compact" {
            let json = encodeJSON(mcpPayload) ?? "{}"
            return CallTool.Result(
                content: [
                    .text(text: json, annotations: nil, _meta: nil),
                ],
                isError: false
            )
        }

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

    static func structuredErrorResult(
        message: String,
        code: String,
        fields: [String: AgentBrokerValue]
    ) -> CallTool.Result {
        var payload: [String: Value] = [
            "code": .string(code),
            "message": .string(message),
        ]
        for (key, value) in fields {
            if key == "code" || key == "message" { continue }
            payload[key] = mcpValue(from: value)
        }
        let json = encodeJSON(.object(payload)) ?? "{}"
        return CallTool.Result(
            content: [
                .text(text: message, annotations: nil, _meta: nil),
                .resource(resource: .text(json, uri: "wax://errors/\(code)", mimeType: "application/json")),
            ],
            isError: true
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

#endif
