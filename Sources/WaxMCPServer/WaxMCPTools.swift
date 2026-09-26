#if MCPServer
import Foundation
import MCP
import Wax
import WaxCore

/// Lazily queried MCP client roots, keyed by transport/connection key.
///
/// The provider closure captures the connection's `Server` actor, so it lives
/// in this registry instead of on `MCPClientSessionHint`: the server retains
/// its method handlers, which retain the hint, and actors cannot be held
/// weakly. Entries are removed on transport teardown.
enum MCPRootsProviderRegistry {
    static let shared = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var providers: [String: (@Sendable () async -> [String])] = [:]

        func remember(key: String, provider: @escaping @Sendable () async -> [String]) {
            lock.lock()
            defer { lock.unlock() }
            providers[key] = provider
        }

        func current(key: String) -> (@Sendable () async -> [String])? {
            lock.lock()
            defer { lock.unlock() }
            return providers[key]
        }

        func remove(key: String) {
            lock.lock()
            defer { lock.unlock() }
            providers.removeValue(forKey: key)
        }

        func resetForTests() {
            lock.lock()
            defer { lock.unlock() }
            providers.removeAll()
        }
    }
}

/// `roots/list` fetch with a timeout. Never throws: a missing roots
/// capability, a client that never answers (no HTTP GET stream held), and
/// transport errors all yield an empty list so attribution falls back to
/// explicit `cwd`/`project`/`repo` arguments.
enum MCPRootsFetcher {
    /// Bound for one roots round-trip. Only failing calls pay it: the refresh
    /// runs solely when a project-gated call would otherwise throw, plus one
    /// background fetch on initialized/roots-changed notifications.
    static let timeoutSeconds: TimeInterval = 2

    static func fetchRoots(server: Server) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                do {
                    let roots = try await server.listRoots()
                    return MCPRootsMapper.paths(fromURIs: roots.map(\.uri))
                } catch {
                    return []
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }
}

enum MCPRootsRefresher {
    /// Background refresh after initialize/roots-changed. Never blocks the
    /// notification handler: the caller spawns this in a detached task so the
    /// server receive loop stays free to deliver the `roots/list` response.
    static func refresh(connectionKey: String, hint: MCPClientSessionHint?) async {
        guard let provider = MCPRootsProviderRegistry.shared.current(key: connectionKey) else { return }
        let roots = await provider()
        guard !roots.isEmpty else { return }
        hint?.updateRoots(roots)
        if var stored = MCPHTTPConnectionContextRegistry.shared.current(sessionID: connectionKey) {
            stored.mcpRoots = roots
            MCPHTTPConnectionContextRegistry.shared.remember(sessionID: connectionKey, context: stored)
        } else if let hintContext = hint?.connectionContext() {
            MCPHTTPConnectionContextRegistry.shared.remember(sessionID: connectionKey, context: hintContext)
        } else {
            MCPHTTPConnectionContextRegistry.shared.remember(
                sessionID: connectionKey,
                context: MCPConnectionContext(transportKey: connectionKey, mcpRoots: roots)
            )
        }
    }
}

/// Project-gating failure with the exact inputs seen, so the error can tell
/// the caller what to retry with instead of failing opaquely again.
struct MCPProjectUnresolvedDetail: Error, Sendable {
    var missing: [String]
    var cwd: String?
    var roots: [String]
    var hasExplicit: Bool
}

enum WaxMCPTools {
    static let projectUnresolvedNextAction = "retry once with cwd=<workspace root>"

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

        // Capture `roots/list` on initialize (stdio + HTTP) into the
        // connection context. The handler only retains the hint/key; the
        // server-capturing fetch lives in the provider registry, and the
        // refresh runs detached so the receive loop can deliver the reply.
        if let connectionKey {
            let key = connectionKey
            _ = await server.onNotification(InitializedNotification.self) { _ in
                Task { await MCPRootsRefresher.refresh(connectionKey: key, hint: sessionHint) }
            }
            _ = await server.onNotification(RootsListChangedNotification.self) { _ in
                Task { await MCPRootsRefresher.refresh(connectionKey: key, hint: sessionHint) }
            }
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
            } catch let detail as MCPProjectUnresolvedDetail {
                return projectUnresolvedErrorResult(detail)
            } catch let error as MCPAutoSessionError {
                return autoSessionErrorResult(error)
            }
            // The connection supplies a default, not an ownership boundary.
            // Explicit UUIDs are validated against persisted sessions by the broker.
            injectClientSessionIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
            injectClientCWDIfNeeded(name: params.name, arguments: &forwarded, sessionHint: sessionHint)
            migrateLegacyFilterKeysIfNeeded(name: params.name, arguments: &forwarded)
            try validateArgumentSurface(name: params.name, arguments: forwarded)
            let verbosity = try responseVerbosity(from: forwarded) ?? .compact

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
                } catch let detail as MCPProjectUnresolvedDetail {
                    return projectUnresolvedErrorResult(detail)
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
    private var ids: [String: UUID] = [:]
    private var ownerships: [String: MCPMemoryOwnership] = [:]
    private var reverse: [UUID: Set<String>] = [:]

    func current(for key: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return ids[key]
    }

    func ownership(for key: String) -> MCPMemoryOwnership? {
        lock.lock()
        defer { lock.unlock() }
        return ownerships[key]
    }

    func remember(key: String, sessionID: UUID?, ownership: MCPMemoryOwnership? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = ids[key] {
            reverse[previous]?.remove(key)
            if reverse[previous]?.isEmpty == true {
                reverse.removeValue(forKey: previous)
            }
        }
        if let sessionID {
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

    func invalidate(sessionID: UUID) {
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
    private var sessionID: UUID?
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

    func current() -> UUID? {
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

    /// Initialize/roots-changed capture target. Overwrites the cached list;
    /// empty fetches never clear so a transient `roots/list` failure cannot
    /// wipe attribution that already resolved.
    func updateRoots(_ roots: [String]) {
        guard !roots.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var updated = context ?? MCPConnectionContext(transportKey: connectionKey ?? "")
        updated.mcpRoots = roots
        context = updated
    }

    /// Fetch client roots when attribution needs them. Non-empty results are
    /// cached on the connection context; empty results re-query on the next
    /// unresolved gated call so late-advertised roots still heal the
    /// connection.
    func refreshRootsIfNeeded() async {
        guard let connectionKey, !hasCachedRoots else { return }
        guard let provider = MCPRootsProviderRegistry.shared.current(key: connectionKey) else { return }
        let roots = await provider()
        guard !roots.isEmpty else { return }
        updateRoots(roots)
        if var stored = MCPHTTPConnectionContextRegistry.shared.current(sessionID: connectionKey) {
            stored.mcpRoots = roots
            MCPHTTPConnectionContextRegistry.shared.remember(sessionID: connectionKey, context: stored)
        }
    }

    private var hasCachedRoots: Bool {
        lock.lock()
        defer { lock.unlock() }
        return context?.mcpRoots.isEmpty == false
    }

    func remember(name: String, payload: AgentBrokerValue) {
        switch name {
        case "session_start", "session_resume", "session_open":
            if let sessionID = Self.workingSessionID(from: payload) {
                bind(sessionID, ownership: ownership ?? .transport)
            }
        case "session_end", "session_close":
            if let ended = Self.workingSessionID(from: payload) {
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

    func bind(_ sessionID: UUID?, ownership: MCPMemoryOwnership?) {
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

    private static func workingSessionID(from payload: AgentBrokerValue) -> UUID? {
        guard let raw = payload.objectValue?["session_id"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
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

    static func autoEnsureSessionIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async throws {
        let canonical = BrokerCommandCatalog.canonicalCommand(for: name) ?? name
        guard ["remember", "recall", "memory_append"].contains(canonical) else { return }
        guard MCPAutoSessionPolicy.isEnabled() else { return }
        guard arguments["session_id"] == nil else { return }
        guard let hint = sessionHint, let transportKey = hint.transportKey() else { return }
        if hint.current() != nil { return }

        let explicitProject = nonEmptyString(arguments["project"])
        let explicitRepo = nonEmptyString(arguments["repo"])
        let explicitCWD = nonEmptyString(arguments["cwd"])
        func resolveAttribution(advertisedCWD: String?, mcpRoots: [String]) -> MCPProjectAttribution {
            MCPProjectAttributionResolver.resolve(
                explicitProject: explicitProject,
                explicitRepo: explicitRepo,
                advertisedCWD: explicitCWD ?? advertisedCWD,
                mcpRoots: mcpRoots
            )
        }
        var context = hint.connectionContext() ?? MCPConnectionContext(transportKey: transportKey)
        var attribution = resolveAttribution(
            advertisedCWD: context.advertisedCWD,
            mcpRoots: context.mcpRoots
        )
        // Sticky fallback: a connection that resolved once keeps working when
        // later calls omit cwd/project/repo (e.g. after session_end cleared
        // the binding). Explicit args always win over the sticky value.
        if !attribution.isResolved,
           explicitProject == nil, explicitRepo == nil, explicitCWD == nil,
           let sticky = MCPStickyAttributionRegistry.shared.current(for: transportKey),
           sticky.isResolved {
            attribution = sticky
        }
        let projectGated = try projectGatedAutoSession(
            command: canonical,
            arguments: arguments
        )
        if projectGated && !attribution.isResolved {
            await hint.refreshRootsIfNeeded()
            context = hint.connectionContext() ?? context
            attribution = resolveAttribution(
                advertisedCWD: context.advertisedCWD,
                mcpRoots: context.mcpRoots
            )
            if !attribution.isResolved,
               explicitProject == nil, explicitRepo == nil, explicitCWD == nil,
               let sticky = MCPStickyAttributionRegistry.shared.current(for: transportKey),
               sticky.isResolved {
                attribution = sticky
            }
        }
        if projectGated && !attribution.isResolved {
            throw MCPProjectUnresolvedDetail(
                missing: ["cwd", "project", "repo"],
                cwd: explicitCWD ?? context.advertisedCWD,
                roots: context.mcpRoots,
                hasExplicit: explicitProject != nil || explicitRepo != nil
            )
        }
        if !projectGated && !attribution.isResolved {
            return
        }

        if attribution.isResolved {
            MCPStickyAttributionRegistry.shared.remember(
                transportKey: transportKey,
                attribution: attribution
            )
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

    /// Parse remember/recall enums from the MCP bag, then apply typed project gates.
    /// Invalid remember `scope` fails like `BrokerCommand.parseRememberWriteScope`.
    static func projectGatedAutoSession(
        command: String,
        arguments: [String: Value]
    ) throws -> Bool {
        let args = BrokerArguments(arguments.mapValues(brokerValue(from:)))
        do {
            if command == "recall" {
                return MCPProjectAttributionResolver.isProjectGatedRecall(
                    scope: try BrokerCommand.parseRecallScope(args)
                )
            }
            let memoryType = try args.optionalString("memory_type").flatMap(MemoryType.init(rawValue:))
            return MCPProjectAttributionResolver.isProjectScopedWrite(
                memoryType: memoryType,
                scope: try BrokerCommand.parseRememberWriteScope(args)
            )
        } catch let error as BrokerValidationError {
            throw ToolValidationError.invalid(error.localizedDescription)
        }
    }

    static func injectClientCWDIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?
    ) {
        guard arguments["cwd"] == nil else { return }
        let canonical = BrokerCommandCatalog.canonicalCommand(for: name) ?? name
        guard ["remember", "recall", "memory_append", "session_open", "session_start"].contains(canonical) else {
            return
        }
        if let cwd = sessionHint?.connectionContext()?.advertisedCWD
            ?? sessionHint?.connectionContext()?.canonicalMCPRoot {
            arguments["cwd"] = .string(cwd)
            return
        }
        if let key = sessionHint?.transportKey(),
           let cwd = MCPStickyAttributionRegistry.shared.current(for: key)?.cwdPath {
            arguments["cwd"] = .string(cwd)
        }
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
        let canonical = BrokerCommandCatalog.canonicalCommand(for: name) ?? name
        return ["remember", "recall", "memory_append"].contains(canonical)
    }

    static func clearStaleInjectedBinding(sessionHint: MCPClientSessionHint?) {
        guard let sessionID = sessionHint?.current() else { return }
        MCPBoundSessionRegistry.shared.invalidate(sessionID: sessionID)
        sessionHint?.clearBinding()
    }

    /// Backward compat for pre-filters clients (e.g. v0.1.47) that send
    /// recall/search filter keys top-level instead of nested under `filters`.
    /// Migrates `labels`, `frame_ids`, `time_after_ms`, `time_before_ms`,
    /// `include_deleted`, `include_superseded`, `include_surrogates` into
    /// `filters` so old tool definitions keep working. New clients should
    /// pass `filters` directly.
    static func migrateLegacyFilterKeysIfNeeded(
        name: String,
        arguments: inout [String: Value]
    ) {
        let canonical = BrokerCommandCatalog.canonicalCommand(for: name) ?? name
        guard ["recall", "search"].contains(canonical) else { return }
        // Don't hide a filters type error: if filters exists and is neither
        // object nor null, leave everything alone so validation reports it.
        if let existingFilters = arguments["filters"], existingFilters != .null {
            guard case .object = existingFilters else { return }
        }
        let legacyKeys = [
            "labels",
            "frame_ids",
            "time_after_ms",
            "time_before_ms",
            "include_deleted",
            "include_superseded",
            "include_surrogates",
        ]
        // Explicit nulls mean absent (consistent with BrokerArguments); drop
        // them so they don't trip unknown-arg validation or pollute filters.
        for key in legacyKeys where arguments[key] == .null {
            arguments.removeValue(forKey: key)
        }
        let present = legacyKeys.filter { arguments[$0] != nil }
        guard !present.isEmpty else { return }
        var merged: [String: Value]
        if case .object(let existing) = arguments["filters"] {
            merged = existing
        } else {
            merged = [:]
        }
        for key in present {
            // Explicit `filters.*` wins over legacy top-level on conflict.
            if merged[key] == nil, let value = arguments[key] {
                merged[key] = value
            }
            arguments.removeValue(forKey: key)
        }
        arguments["filters"] = .object(merged)
    }

    static func injectClientSessionIfNeeded(
        name: String,
        arguments: inout [String: Value],
        sessionHint: MCPClientSessionHint?
    ) {
        guard arguments["session_id"] == nil else { return }
        guard let sessionID = sessionHint?.current() else { return }
        switch BrokerCommandCatalog.canonicalCommand(for: name) ?? name {
        case "stats", "recall", "search", "memory_search", "corpus_search",
             "compact_context", "session_close", "session_end", "handoff":
            arguments["session_id"] = .string(sessionID.uuidString)
        case "session_open":
            if nonEmptyString(arguments["conversation_id"]) != nil { return }
            if nonEmptyString(arguments["agent_id"]) != nil { return }
            if nonEmptyString(arguments["run_id"]) != nil { return }
            arguments["session_id"] = .string(sessionID.uuidString)
        case "session_resume":
            // Selectors intentionally target another session; an empty resume
            // should recover this connection, not search every agent's manifests.
            if nonEmptyString(arguments["agent_id"]) != nil { return }
            if nonEmptyString(arguments["run_id"]) != nil { return }
            arguments["session_id"] = .string(sessionID.uuidString)
        case "remember":
            if let scope = nonEmptyString(arguments["scope"])?.lowercased(), scope == "durable" {
                return
            }
            arguments["session_id"] = .string(sessionID.uuidString)
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
        guard let entry = BrokerCommandCatalog.entry(for: name), entry.exposure == .publicCommand else {
            throw ToolValidationError.invalid("Unknown tool '\(name)'.")
        }
        if entry.requiresStructuredMemory, !structuredMemoryEnabled {
            throw ToolValidationError.invalid("tool '\(name)' requires structured memory to be enabled")
        }
    }

    static func validateArgumentSurface(name: String, arguments: [String: Value]?) throws {
        do {
            try BrokerCommandCatalog.validateArgumentSurface(
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
    static func projectUnresolvedErrorResult(_ detail: MCPProjectUnresolvedDetail) -> CallTool.Result {
        var received: [String: AgentBrokerValue] = [
            "roots": .array(detail.roots.map(AgentBrokerValue.string)),
            "explicit": .bool(detail.hasExplicit),
        ]
        if let cwd = detail.cwd {
            received["cwd"] = .string(cwd)
        } else {
            received["cwd"] = .null
        }
        return structuredErrorResult(
            message: "project identity is unresolved; pass cwd, project, or advertise one MCP root",
            code: "project_unresolved",
            fields: [
                "committed": .bool(false),
                "missing": .array(detail.missing.map(AgentBrokerValue.string)),
                "received": .object(received),
                "next_action": .string(projectUnresolvedNextAction),
            ]
        )
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
                    "received": .object([
                        "cwd": .null,
                        "roots": .array([]),
                        "explicit": .bool(false),
                    ]),
                    "next_action": .string(projectUnresolvedNextAction),
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
        case .collisionResumeFailed(let message, let retryable, let nextAction):
            return structuredErrorResult(
                message: message,
                code: "auto_session_failed",
                fields: [
                    "committed": .bool(false),
                    "retryable": .bool(retryable),
                    "next_action": .string(nextAction),
                ]
            )
        }
    }

    static func responseVerbosity(from arguments: [String: Value]) throws -> ResponseVerbosity? {
        guard let value = arguments["verbosity"] else { return nil }
        guard case .string(let raw) = value else {
            throw ToolValidationError.invalid("verbosity must be a string: compact or verbose")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let verbosity = ResponseVerbosity(rawValue: trimmed) else {
            throw ToolValidationError.invalid("verbosity must be one of: compact, verbose")
        }
        return verbosity
    }

    static func renderResult(
        name: String,
        payload: AgentBrokerValue,
        verbosity: ResponseVerbosity = .compact
    ) -> CallTool.Result {
        var presented = payload
        if name == "compact_context", verbosity != .verbose, var object = payload.objectValue {
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
            removing: verbosity == .verbose ? ["display_text"] : compactPresentationKeys
        ))
        switch verbosity {
        case .compact:
            return jsonResult(compactPayload)
        case .verbose:
            let json = encodeJSON(compactPayload) ?? "{}"
            return CallTool.Result(
                content: [
                    .text(text: json, annotations: nil, _meta: nil),
                ],
                structuredContent: Optional.some(compactPayload),
                isError: false
            )
        }
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
