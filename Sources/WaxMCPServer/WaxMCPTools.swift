#if MCPServer
import Foundation
import MCP
import Wax
import WaxCore

enum WaxMCPTools {
    static func register(
        on server: Server,
        brokerConfiguration: AgentBrokerConfiguration,
        structuredMemoryEnabled: Bool,
        connectionKey: String? = nil,
        connectionContext: MCPConnectionContext? = nil
    ) async {
        let sessionHint = MCPClientSessionHint(connectionKey: connectionKey, context: connectionContext)
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
        structuredMemoryEnabled: Bool = true,
        sessionHint: MCPClientSessionHint? = nil
    ) async -> CallTool.Result {
        await executeCall(
            params: params,
            structuredMemoryEnabled: structuredMemoryEnabled,
            sessionHint: sessionHint
        ) { request in
            await broker.handle(request)
        }
    }

    private static func executeCall(
        params: CallTool.Parameters,
        structuredMemoryEnabled: Bool,
        sessionHint: MCPClientSessionHint?,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async -> CallTool.Result {
        do {
            if let migration = migratedName(for: params.name) {
                return errorResult(
                    message: "tool '\(params.name)' has been renamed to '\(migration)'",
                    code: "tool_renamed"
                )
            }

            try validateToolAvailability(name: params.name, structuredMemoryEnabled: structuredMemoryEnabled)

            var forwarded = params.arguments ?? [:]
            if let oversize = contentLimitError(name: params.name, arguments: forwarded) {
                return oversize
            }
            let hadExplicitSession = forwarded["session_id"] != nil
            do {
                try await autoEnsureSessionIfNeeded(
                    name: params.name,
                    arguments: &forwarded,
                    sessionHint: sessionHint,
                    perform: perform
                )
            } catch let error as MCPAutoSessionError {
                return autoSessionErrorResult(error)
            }
            // The connection supplies a default, not an ownership boundary.
            // Explicit UUIDs are validated against persisted sessions by the broker.
            injectClientSessionIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
            injectClientCWDIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
            try validateArgumentSurface(name: params.name, arguments: forwarded)
            let verbosity = try responseVerbosity(from: forwarded) ?? "compact"

            var response = try await perform(
                AgentBrokerRequest(
                    command: params.name,
                    arguments: forwarded.mapValues(brokerValue(from:))
                )
            )
            if !hadExplicitSession,
               shouldRetryInactiveBinding(name: params.name, response: response, sessionHint: sessionHint) {
                clearStaleInjectedBinding(sessionHint: sessionHint)
                forwarded.removeValue(forKey: "session_id")
                do {
                    try await autoEnsureSessionIfNeeded(
                        name: params.name,
                        arguments: &forwarded,
                        sessionHint: sessionHint,
                        perform: perform
                    )
                } catch let error as MCPAutoSessionError {
                    return autoSessionErrorResult(error)
                }
                injectClientSessionIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
                injectClientCWDIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
                response = try await perform(
                    AgentBrokerRequest(
                        command: params.name,
                        arguments: forwarded.mapValues(brokerValue(from:))
                    )
                )
            }

            switch response.outcome {
            case .failure(let payload, let message):
                if let fields = payload?.objectValue,
                   let code = fields["code"]?.stringValue {
                    return structuredErrorResult(
                        message: message,
                        code: code,
                        fields: fields
                    )
                }
                return errorResult(message: message, code: errorCode(for: message))
            case .success:
                guard let payload = response.payload else {
                    return errorResult(message: "Broker returned an empty payload", code: "execution_failed")
                }
                sessionHint?.remember(name: params.name, payload: payload)
                return renderResult(name: params.name, payload: payload, verbosity: verbosity)
            }
        } catch let error as ToolValidationError {
            return errorResult(message: error.localizedDescription, code: "invalid_arguments")
        } catch {
            let message = error.localizedDescription
            if message.contains("did not answer") || message.contains("socket_live=true") {
                return structuredErrorResult(
                    message: message,
                    code: "broker_unresponsive",
                    fields: [
                        "committed": .bool(false),
                        "socket_live": .bool(true),
                        "answered": .bool(false),
                        "next_action": .string(
                            "Restart wax-mcp or launchctl kickstart the HTTP service, then session_open with conversation_id. The write did not land; do not spawn children."
                        ),
                    ]
                )
            }
            return errorResult(message: message, code: "execution_failed")
        }
    }
}

/// Process-wide Wax session binding keyed by MCP HTTP/stdio connection id.
/// Survives `Server` recreate under the same `Mcp-Session-Id`.
final class MCPBoundSessionRegistry: @unchecked Sendable {
    static let shared = MCPBoundSessionRegistry()
    private let lock = NSLock()
    private var ids: [String: String] = [:]
    private var ownerships: [String: MCPMemoryOwnership] = [:]
    private var reverse: [String: Set<String>] = [:]

    func current(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ids[key]
    }

    func ownership(for key: String) -> MCPMemoryOwnership? {
        lock.lock()
        defer { lock.unlock() }
        return ownerships[key]
    }

    func remember(key: String, sessionID: String?, ownership: MCPMemoryOwnership? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = ids[key] {
            reverse[previous]?.remove(key)
            if reverse[previous]?.isEmpty == true {
                reverse.removeValue(forKey: previous)
            }
        }
        if let sessionID, !sessionID.isEmpty {
            ids[key] = sessionID
            ownerships[key] = ownership ?? ownerships[key] ?? .transport
            var keys = reverse[sessionID] ?? []
            keys.insert(key)
            reverse[sessionID] = keys
        } else {
            ids.removeValue(forKey: key)
            ownerships.removeValue(forKey: key)
        }
    }

    func invalidate(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        let keys = reverse.removeValue(forKey: sessionID) ?? []
        for key in keys {
            ids.removeValue(forKey: key)
            ownerships.removeValue(forKey: key)
            MCPAutoSessionCoordinatorStore.shared.remove(for: key)
        }
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        ids.removeAll()
        ownerships.removeAll()
        reverse.removeAll()
        MCPAutoSessionCoordinatorStore.shared.resetForTests()
    }
}

/// Per MCP `Server` session id. HTTP creates one Server per client session; stdio has one Server.
final class MCPClientSessionHint: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionID: String?
    private var ownership: MCPMemoryOwnership?
    private let connectionKey: String?
    private var context: MCPConnectionContext?

    init(connectionKey: String? = nil, context: MCPConnectionContext? = nil) {
        self.connectionKey = connectionKey ?? context?.transportKey
        self.context = context
        if let key = self.connectionKey {
            sessionID = MCPBoundSessionRegistry.shared.current(for: key)
            ownership = MCPBoundSessionRegistry.shared.ownership(for: key)
            if self.context == nil, let stored = MCPHTTPConnectionContextRegistry.shared.current(sessionID: key) {
                self.context = stored
            }
        }
    }

    func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let sessionID { return sessionID }
        if let connectionKey {
            return MCPBoundSessionRegistry.shared.current(for: connectionKey)
        }
        return nil
    }

    func currentOwnership() -> MCPMemoryOwnership? {
        lock.lock()
        defer { lock.unlock() }
        if let ownership { return ownership }
        if let connectionKey {
            return MCPBoundSessionRegistry.shared.ownership(for: connectionKey)
        }
        return nil
    }

    func connectionContext() -> MCPConnectionContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    func transportKey() -> String? {
        connectionKey
    }

    func remember(name: String, payload: AgentBrokerValue) {
        switch name {
        case "session_start", "session_resume", "session_open":
            if let sessionID = payload.objectValue?["session_id"]?.stringValue {
                bind(sessionID, ownership: ownership ?? .transport)
            }
        case "session_end", "session_close":
            if let ended = payload.objectValue?["session_id"]?.stringValue {
                lock.lock()
                let matches = sessionID == ended
                lock.unlock()
                if matches {
                    bind(nil, ownership: nil)
                }
            }
        default:
            break
        }
    }

    func bind(_ sessionID: String?, ownership: MCPMemoryOwnership?) {
        lock.lock()
        self.sessionID = sessionID
        self.ownership = ownership
        lock.unlock()
        if let connectionKey {
            MCPBoundSessionRegistry.shared.remember(
                key: connectionKey,
                sessionID: sessionID,
                ownership: ownership
            )
        }
    }

    func clearBinding() {
        bind(nil, ownership: nil)
        if let connectionKey {
            MCPAutoSessionCoordinatorStore.shared.remove(for: connectionKey)
        }
    }
}

private extension WaxMCPTools {
    static let compactPresentationKeys: Set<String> = [
        "display_text", "storePath", "store_path", "event_log_path",
        "root_path", "corpus_store_path", "source_store_path",
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

    static func responseVerbosity(from arguments: [String: Value]) throws -> String? {
        guard let value = arguments["verbosity"] else { return nil }
        guard case .string(let raw) = value else {
            throw ToolValidationError.invalid("verbosity must be a string: compact or verbose")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "compact" || trimmed == "verbose" else {
            throw ToolValidationError.invalid("verbosity must be one of: compact, verbose")
        }
        return trimmed
    }

    static func autoEnsureSessionIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async throws {
        let canonical = AgentBrokerCommandSurface.entry(for: name)?.canonicalName ?? name
        guard ["remember", "recall", "memory_append"].contains(canonical) else { return }
        guard MCPAutoSessionPolicy.isEnabled() else { return }
        guard arguments["session_id"] == nil else { return }
        guard let hint = sessionHint, let transportKey = hint.transportKey() else { return }
        if hint.current() != nil { return }

        let context = hint.connectionContext() ?? MCPConnectionContext(transportKey: transportKey)
        let attribution = MCPProjectAttributionResolver.resolve(
            explicitProject: nonEmptyString(arguments["project"]),
            explicitRepo: nonEmptyString(arguments["repo"]),
            advertisedCWD: nonEmptyString(arguments["cwd"]) ?? context.advertisedCWD,
            mcpRoots: context.mcpRoots
        )
        let memoryType = nonEmptyString(arguments["memory_type"])
        let scope = nonEmptyString(arguments["scope"])
        let projectGated: Bool
        if canonical == "recall" {
            projectGated = MCPProjectAttributionResolver.isProjectGatedRecall(scope: scope)
        } else {
            projectGated = MCPProjectAttributionResolver.isProjectScopedWrite(
                memoryType: memoryType,
                scope: scope
            )
        }
        if projectGated && !attribution.isResolved {
            throw MCPAutoSessionError.projectUnresolved(missing: ["cwd", "mcp_root", "project"])
        }
        if !projectGated && !attribution.isResolved {
            return
        }

        let coordinator = MCPAutoSessionCoordinatorStore.shared.coordinator(for: transportKey)
        let binding = try await coordinator.ensureBound(
            transportKey: transportKey,
            attribution: attribution,
            context: context,
            perform: { request in try await perform(request) }
        )
        hint.bind(binding.sessionID, ownership: binding.ownership)
        if arguments["cwd"] == nil, let cwd = attribution.cwdPath {
            arguments["cwd"] = .string(cwd)
        }
    }

    static func injectClientCWDIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?
    ) {
        guard arguments["cwd"] == nil else { return }
        let canonical = AgentBrokerCommandSurface.entry(for: name)?.canonicalName ?? name
        guard ["remember", "recall", "memory_append", "session_open", "session_start"].contains(canonical) else {
            return
        }
        guard let cwd = sessionHint?.connectionContext()?.advertisedCWD
            ?? sessionHint?.connectionContext()?.canonicalMCPRoot else {
            return
        }
        arguments["cwd"] = .string(cwd)
    }

    static func shouldRetryInactiveBinding(
        name: String,
        response: AgentBrokerResponse,
        sessionHint: MCPClientSessionHint?
    ) -> Bool {
        guard sessionHint?.current() != nil else { return false }
        guard argumentsWereInjected(name: name) else { return false }
        guard case .failure(let payload, _) = response.outcome else { return false }
        let code = payload?.objectValue?["code"]?.stringValue
        return code == "session_ended" || code == "session_unknown" || code == "session_not_live"
    }

    static func argumentsWereInjected(name: String) -> Bool {
        let canonical = AgentBrokerCommandSurface.entry(for: name)?.canonicalName ?? name
        return ["remember", "recall", "memory_append"].contains(canonical)
    }

    static func clearStaleInjectedBinding(sessionHint: MCPClientSessionHint?) {
        guard let sessionID = sessionHint?.current() else { return }
        MCPBoundSessionRegistry.shared.invalidate(sessionID: sessionID)
        sessionHint?.clearBinding()
    }

    static func autoSessionErrorResult(_ error: MCPAutoSessionError) -> CallTool.Result {
        switch error {
        case .projectUnresolved(let missing):
            return structuredErrorResult(
                message: "project identity is unresolved; pass cwd, project, or advertise one MCP root",
                code: "project_unresolved",
                fields: [
                    "committed": .bool(false),
                    "missing": .array(missing.map(AgentBrokerValue.string)),
                ]
            )
        case .openFailed(let message, let retryable):
            return structuredErrorResult(
                message: message,
                code: "auto_session_failed",
                fields: [
                    "committed": .bool(false),
                    "retryable": .bool(retryable),
                ]
            )
        }
    }

    static func injectClientSessionIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?
    ) {
        guard arguments["session_id"] == nil else { return }
        guard let sessionID = sessionHint?.current() else { return }
        switch AgentBrokerCommandSurface.entry(for: name)?.canonicalName ?? name {
        case "stats", "recall", "search", "memory_search", "corpus_search",
             "compact_context", "session_close", "session_end", "handoff":
            arguments["session_id"] = .string(sessionID)
        case "session_open":
            if nonEmptyString(arguments["conversation_id"]) != nil { return }
            if nonEmptyString(arguments["agent_id"]) != nil { return }
            if nonEmptyString(arguments["run_id"]) != nil { return }
            arguments["session_id"] = .string(sessionID)
        case "session_resume":
            // Selectors intentionally target another session; an empty resume
            // should recover this connection, not search every agent's manifests.
            if nonEmptyString(arguments["agent_id"]) != nil { return }
            if nonEmptyString(arguments["run_id"]) != nil { return }
            arguments["session_id"] = .string(sessionID)
        case "remember":
            if let scope = nonEmptyString(arguments["scope"])?.lowercased(), scope == "durable" {
                return
            }
            arguments["session_id"] = .string(sessionID)
        default:
            break
        }
    }

    static func nonEmptyString(_ value: Value?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validateToolAvailability(name: String, structuredMemoryEnabled: Bool) throws {
        guard let entry = AgentBrokerCommandSurface.entry(for: name), entry.exposure == .publicCommand else {
            throw ToolValidationError.invalid("Unknown tool '\(name)'.")
        }
        if entry.requiresStructuredMemory, !structuredMemoryEnabled {
            throw ToolValidationError.invalid("tool '\(name)' requires structured memory to be enabled")
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
        case "wax_task_state_migrate": return "task_state_migrate"
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

}

extension WaxMCPTools {
    static func renderResult(
        name: String,
        payload: AgentBrokerValue,
        verbosity: String? = nil
    ) -> CallTool.Result {
        var presented = payload
        if name == "compact_context", verbosity != "verbose", var object = payload.objectValue {
            // The checkpoint text has already been token-budgeted. Keep memory
            // references for follow-up reads without repeating full source bodies.
            object.removeValue(forKey: "summary")
            for key in ["short_context", "medium_context", "long_context"] {
                if let rows = object[key]?.arrayValue {
                    object[key] = .array(rows.map { row in
                        guard var hit = row.objectValue else { return row }
                        hit.removeValue(forKey: "text")
                        hit.removeValue(forKey: "preview")
                        return .object(hit)
                    })
                }
            }
            presented = .object(object)
        }
        let compactPayload = mcpValue(from: removingPresentationFields(
            from: presented,
            removing: verbosity == "verbose" ? ["display_text"] : compactPresentationKeys
        ))
        if verbosity == "compact" {
            let json = encodeJSON(compactPayload) ?? "{}"
            return CallTool.Result(
                content: [
                    .text(text: json, annotations: nil, _meta: nil),
                ],
                isError: false
            )
        }

        if verbosity == "verbose" {
            let json = encodeJSON(compactPayload) ?? "{}"
            return CallTool.Result(
                content: [
                    .text(text: json, annotations: nil, _meta: nil),
                ],
                structuredContent: Optional.some(compactPayload),
                isError: false
            )
        }

        return jsonResult(compactPayload)
    }
}

private extension WaxMCPTools {
    static func removingPresentationFields(
        from payload: AgentBrokerValue,
        removing keys: Set<String>,
        preservingUserFields: Bool = false
    ) -> AgentBrokerValue {
        switch payload {
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, entry in
                guard preservingUserFields || !keys.contains(entry.key) else { return }
                result[entry.key] = removingPresentationFields(
                    from: entry.value,
                    removing: keys,
                    preservingUserFields: preservingUserFields || entry.key == "metadata"
                )
            })
        case .array(let values):
            return .array(values.map {
                removingPresentationFields(
                    from: $0,
                    removing: keys,
                    preservingUserFields: preservingUserFields
                )
            })
        case .null, .bool, .int, .double, .string:
            return payload
        }
    }

    static func jsonResult(_ value: Value) -> CallTool.Result {
        let json = encodeJSON(value) ?? "{}"
        return CallTool.Result(
            content: [
                .text(text: json, annotations: nil, _meta: nil),
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
                .text(text: json, annotations: nil, _meta: nil),
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
                .text(text: json, annotations: nil, _meta: nil),
                .resource(resource: .text(json, uri: "wax://errors/\(code)", mimeType: "application/json")),
            ],
            isError: true
        )
    }

    static func encodeJSON(_ value: Value) -> String? {
        let object = toJSONObject(value)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8),
              !json.isEmpty else {
            return nil
        }
        return json
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
            return value.isFinite ? value : NSNull()
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
