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

extension WaxMCPTools {
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

enum ToolValidationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

#endif
