#if MCPServer
import Foundation
import Logging
import MCP
import Wax
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

actor MCPHTTPApplication {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var endpoint: String
        var sessionTimeout: TimeInterval
        var sessionCleanupInterval: Duration
        var retryInterval: Int?
        var maxRequestBodyBytes: Int
        var authToken: String?
        /// Live session cap. Creating a session beyond it evicts the least
        /// recently used one, preferring sessions without an open SSE stream;
        /// clients recover under their old id on next use.
        var maxSessions: Int
        /// Upper bound on how long shutdown waits for session teardown.
        var shutdownDeadline: Duration

        init(
            host: String = "127.0.0.1",
            port: Int = 3000,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            sessionCleanupInterval: Duration = .seconds(60),
            retryInterval: Int? = nil,
            maxRequestBodyBytes: Int = 1_048_576,
            authToken: String? = nil,
            maxSessions: Int = 256,
            shutdownDeadline: Duration = .seconds(5)
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
            self.sessionCleanupInterval = sessionCleanupInterval
            self.retryInterval = retryInterval
            self.maxRequestBodyBytes = max(1, maxRequestBodyBytes)
            self.authToken = HTTPAuthPolicy.normalizedToken(authToken)
            self.maxSessions = max(1, maxSessions)
            self.shutdownDeadline = shutdownDeadline
        }
    }

    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server
    typealias TransportTeardown = @Sendable (String, MCPTeardownReason) async -> MCPTeardownOutcome

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let onTransportTeardown: TransportTeardown?
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    /// In-flight session creations (initialize or stale-id recovery) keyed by
    /// `Mcp-Session-Id`, so concurrent requests for one id wait for a single
    /// server instead of each building one.
    private var sessionRecoveryTasks: [String: Task<Bool, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?
    /// Creations between `reserveSessionSlot()` and registration.
    private var pendingSessionCreations = 0
    /// Open SSE responses per session; capacity eviction prefers sessions with none.
    private var openStreams: [String: Int] = [:]

    nonisolated let logger: Logger
    nonisolated let maxRequestBodyBytes: Int

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(
        configuration: Configuration = Configuration(),
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        onTransportTeardown: TransportTeardown? = nil,
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.onTransportTeardown = onTransportTeardown
        self.validationPipeline = validationPipeline
        self.maxRequestBodyBytes = configuration.maxRequestBodyBytes
        self.logger = logger ?? Logger(
            label: "wax.mcp.http",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    var endpoint: String { configuration.endpoint }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                MCPHTTPServerPipeline.configure(channel, app: self)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        logger.info(
            "Starting Wax MCP HTTP application",
            metadata: [
                "host": "\(configuration.host)",
                "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)",
            ]
        )

        if HTTPAuthPolicy.requiresAuthentication(host: configuration.host), configuration.authToken == nil {
            throw MCP.MCPError.invalidRequest("HTTP auth token is required when binding off loopback")
        }

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel
        startSessionCleanupTask()
        do {
            try await channel.closeFuture.get()
        } catch {
            await stopSessionCleanupTask()
            try await group.shutdownGracefully()
            throw error
        }
        await stopSessionCleanupTask()
        try await group.shutdownGracefully()
    }

    func stop() async {
        await stopSessionCleanupTask()
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        logger.info("Wax MCP HTTP application stopped")
    }

    func startSessionCleanupTask() {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { await sessionCleanupLoop() }
    }

    func stopSessionCleanupTask() async {
        guard let task = cleanupTask else { return }
        task.cancel()
        await task.value
        cleanupTask = nil
    }

    func hasActiveSessionCleanupTask() -> Bool {
        cleanupTask != nil
    }

    func liveSessionIDs() -> Set<String> {
        Set(sessions.keys)
    }

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if !HTTPAuthPolicy.requiresAuthentication(host: configuration.host),
           !HTTPAuthPolicy.isSafeLoopbackRequest(
               hostHeader: request.header("host"),
               originHeader: request.header("origin")
           ) {
            return .error(
                statusCode: 403,
                .invalidRequest("Forbidden: non-local Host or Origin on loopback endpoint")
            )
        }
        if HTTPAuthPolicy.requiresBearerToken(host: configuration.host, configuredToken: configuration.authToken),
           !HTTPAuthPolicy.isAuthorized(
               requestToken: request.header("authorization"),
               configuredToken: configuration.authToken
           ) {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: missing or invalid bearer token"),
                extraHeaders: ["WWW-Authenticate": "Bearer"]
            )
        }

        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID, reason: .httpDelete)
            }
            if request.method.uppercased() == "GET" {
                return trackingOpenStream(response, sessionID: sessionID)
            }
            return response
        }

        // Unknown or missing session map entry.
        if request.method.uppercased() == "POST", let body = request.body {
            if isInitializeRequest(body) {
                // Reuse the client's id when present so Cursor can keep its cached header
                // after wax-mcp restarts (otherwise a fresh UUID leaves the client stuck).
                return await createSessionAndHandle(request, preferredSessionID: sessionID)
            }
            if let sessionID {
                // Cursor keeps calling tools with a stale Mcp-Session-Id after process
                // restart and does not re-initialize. Recreate under the same id.
                return await recoverSessionAndHandle(request, sessionID: sessionID)
            }
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    /// Client-chosen ids are kept in memory and echoed in headers and logs.
    static let maxClientSessionIDBytes = 128

    private func isValidClientSessionID(_ sessionID: String) -> Bool {
        !sessionID.isEmpty
            && sessionID.utf8.count <= Self.maxClientSessionIDBytes
            && sessionID.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    /// Makes room for one session before it is allocated: evicts while live
    /// plus in-flight creations would reach the cap. Pair with
    /// `registerSession` on success or `releaseSessionSlot()` on failure.
    private func reserveSessionSlot() {
        evictToFit(reserved: pendingSessionCreations)
        pendingSessionCreations += 1
    }

    private func releaseSessionSlot() {
        pendingSessionCreations = max(0, pendingSessionCreations - 1)
    }

    /// Releases the reservation and inserts the session, evicting again so
    /// the cap holds even when concurrent creators reserved before any
    /// victim was left to evict.
    private func registerSession(_ sessionID: String, _ context: SessionContext) {
        releaseSessionSlot()
        evictToFit(reserved: 0)
        sessions[sessionID] = context
    }

    /// Evicts least recently used sessions, preferring ones without an open
    /// SSE stream. Victims leave the table synchronously, so concurrent
    /// creators never pick the same one, and their broker teardown runs
    /// detached instead of on the creator's request.
    private func evictToFit(reserved: Int) {
        while sessions.count + reserved >= configuration.maxSessions,
              let victim = evictionCandidate() {
            logger.warning(
                "HTTP session cap reached; evicting least recently used session",
                metadata: ["sessionID": "\(victim)", "maxSessions": "\(configuration.maxSessions)"]
            )
            evictSession(victim)
        }
    }

    private func evictionCandidate() -> String? {
        let byLeastRecentUse: ((key: String, value: SessionContext), (key: String, value: SessionContext)) -> Bool = {
            $0.value.lastAccessedAt < $1.value.lastAccessedAt
        }
        let idle = sessions.filter { (openStreams[$0.key] ?? 0) == 0 }
        return (idle.min(by: byLeastRecentUse) ?? sessions.min(by: byLeastRecentUse))?.key
    }

    private func evictSession(_ sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        openStreams[sessionID] = nil
        sessionRecoveryTasks[sessionID]?.cancel()
        sessionRecoveryTasks[sessionID] = nil
        MCPHTTPConnectionContextRegistry.shared.remove(sessionID: sessionID)
        MCPRootsProviderRegistry.shared.remove(key: sessionID)
        MCPStickyAttributionRegistry.shared.remove(for: sessionID)
        let teardown = onTransportTeardown
        let logger = logger
        Task {
            if let teardown {
                _ = await teardown(sessionID, .capacityEviction)
            }
            await session.transport.disconnect()
            logger.info(
                "Closed HTTP session",
                metadata: ["sessionID": "\(sessionID)", "reason": "\(MCPTeardownReason.capacityEviction.rawValue)"]
            )
        }
    }

    /// Counts a session's standalone GET stream as open until it ends or the
    /// client stops reading it. POST responses are short-lived and not tracked.
    private func trackingOpenStream(_ response: HTTPResponse, sessionID: String) -> HTTPResponse {
        guard case .stream(let upstream, let headers) = response else { return response }
        openStreams[sessionID, default: 0] += 1
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        let pump = Task {
            do {
                for try await chunk in upstream {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self.streamClosed(sessionID: sessionID)
        }
        continuation.onTermination = { _ in pump.cancel() }
        return .stream(stream, headers: headers)
    }

    private func streamClosed(sessionID: String) {
        guard let open = openStreams[sessionID] else { return }
        openStreams[sessionID] = open > 1 ? open - 1 : nil
    }

    private func resolveSessionID(preferred: String?) -> String {
        if let preferred, isValidClientSessionID(preferred) {
            return preferred
        }
        return UUID().uuidString
    }

    private func createSessionAndHandle(
        _ request: HTTPRequest,
        preferredSessionID: String? = nil
    ) async -> HTTPResponse {
        let sessionID = resolveSessionID(preferred: preferredSessionID)
        // A client-chosen id may already be in creation (a concurrent
        // initialize or stale-id recovery). Use that session rather than
        // build a second server that would replace it and never be torn down.
        var awaited: Task<Bool, Never>?
        while let inFlight = sessionRecoveryTasks[sessionID], inFlight != awaited {
            awaited = inFlight
            _ = await inFlight.value
        }
        if var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            return await session.transport.handleRequest(request)
        }

        let creation = Task<HTTPResponse, Never> {
            await self.startSessionAndHandle(request, sessionID: sessionID)
        }
        let claim = Task<Bool, Never> {
            _ = await creation.value
            return self.sessions[sessionID] != nil
        }
        sessionRecoveryTasks[sessionID] = claim
        let response = await creation.value
        if sessionRecoveryTasks[sessionID] == claim {
            sessionRecoveryTasks[sessionID] = nil
        }
        return response
    }

    private func startSessionAndHandle(_ request: HTTPRequest, sessionID: String) async -> HTTPResponse {
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        reserveSessionSlot()
        do {
            rememberInitializeContext(sessionID: sessionID, request: request, isRecovery: false)
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)
            registerSession(sessionID, SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            ))

            let response = await transport.handleRequest(request)
            if case .error = response {
                await closeSession(sessionID, reason: .recoveryReplacement)
            }
            return response
        } catch {
            releaseSessionSlot()
            MCPHTTPConnectionContextRegistry.shared.remove(sessionID: sessionID)
            MCPRootsProviderRegistry.shared.remove(key: sessionID)
            MCPStickyAttributionRegistry.shared.remove(for: sessionID)
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }

    /// Recreate an HTTP MCP session under the client's existing `Mcp-Session-Id`.
    ///
    /// Used when the in-memory map was wiped (process restart) but the client still
    /// holds the old id. Synthetic `initialize` binds the transport session so
    /// subsequent `tools/call` passes `SessionValidator`.
    private func recoverSessionAndHandle(
        _ request: HTTPRequest,
        sessionID: String
    ) async -> HTTPResponse {
        guard isValidClientSessionID(sessionID) else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Invalid \(HTTPHeaderName.sessionID) header")
            )
        }

        guard await ensureRecoveredSession(sessionID: sessionID) else {
            return .error(
                statusCode: 500,
                .internalError("Failed to recover MCP HTTP session")
            )
        }

        guard var session = sessions[sessionID] else {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        session.lastAccessedAt = Date()
        sessions[sessionID] = session
        return await session.transport.handleRequest(request)
    }

    private func ensureRecoveredSession(sessionID: String) async -> Bool {
        if sessions[sessionID] != nil {
            return true
        }
        if let existing = sessionRecoveryTasks[sessionID] {
            return await existing.value
        }
        let task = Task<Bool, Never> {
            await self.createRecoveredSession(sessionID: sessionID)
        }
        sessionRecoveryTasks[sessionID] = task
        let recovered = await task.value
        if sessionRecoveryTasks[sessionID] == task {
            sessionRecoveryTasks[sessionID] = nil
        }
        return recovered
    }

    private func createRecoveredSession(sessionID: String) async -> Bool {
        if sessions[sessionID] != nil {
            return true
        }

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        reserveSessionSlot()
        var registered = false
        defer {
            if !registered { releaseSessionSlot() }
        }
        do {
            rememberInitializeContext(sessionID: sessionID, request: nil, isRecovery: true)
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)

            let initRequest = HTTPRequest(
                method: "POST",
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                ],
                body: Self.syntheticInitializeBody,
                path: configuration.endpoint
            )
            let initResponse = await transport.handleRequest(initRequest)
            guard await Self.consumeSuccessfulInitializeResponse(initResponse) else {
                MCPHTTPConnectionContextRegistry.shared.remove(sessionID: sessionID)
                MCPRootsProviderRegistry.shared.remove(key: sessionID)
                MCPStickyAttributionRegistry.shared.remove(for: sessionID)
                await transport.disconnect()
                logger.error(
                    "HTTP session recovery initialize failed",
                    metadata: ["sessionID": "\(sessionID)"]
                )
                return false
            }

            // Optional hygiene notification; ignore failures.
            let initializedNotification = HTTPRequest(
                method: "POST",
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                    HTTPHeaderName.sessionID: sessionID,
                ],
                body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8),
                path: configuration.endpoint
            )
            _ = await transport.handleRequest(initializedNotification)

            registerSession(sessionID, SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            ))
            registered = true
            logger.info(
                "Recovered HTTP session after map miss",
                metadata: ["sessionID": "\(sessionID)"]
            )
            return true
        } catch {
            MCPHTTPConnectionContextRegistry.shared.remove(sessionID: sessionID)
            MCPRootsProviderRegistry.shared.remove(key: sessionID)
            MCPStickyAttributionRegistry.shared.remove(for: sessionID)
            await transport.disconnect()
            logger.error(
                "HTTP session recovery failed",
                metadata: [
                    "sessionID": "\(sessionID)",
                    "error": "\(error.localizedDescription)",
                ]
            )
            return false
        }
    }

    private static let syntheticInitializeBody = Data(
        #"{"jsonrpc":"2.0","id":"wax-session-recover","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wax-mcp-session-recover","version":"0.0.0"}}}"#
            .utf8
    )

    private static func consumeSuccessfulInitializeResponse(_ response: HTTPResponse) async -> Bool {
        switch response {
        case .error:
            return false
        case .accepted, .ok:
            // Initialize should return a JSON-RPC result body/stream; bare
            // accepted/ok without payload is not enough to bind the session.
            return false
        case .data(let data, _):
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("\"result\"")
        case .stream(let stream, _):
            do {
                for try await chunk in stream {
                    guard let text = String(data: chunk, encoding: .utf8) else { continue }
                    if text.contains("\"result\"") {
                        return true
                    }
                }
                // Stream finished without a JSON-RPC result — treat as failure so
                // we do not register a half-initialized transport session.
                return false
            } catch {
                return false
            }
        }
    }

    private func rememberInitializeContext(
        sessionID: String,
        request: HTTPRequest?,
        isRecovery: Bool
    ) {
        let identity: MCPClientIdentity
        let roots: [String]
        if isRecovery {
            identity = MCPClientIdentity(
                name: MCPClientIdentity.syntheticRecoveryName,
                version: "0.0.0"
            )
            roots = []
        } else if let body = request?.body {
            identity = MCPInitializeIdentityParser.parse(from: body)
            roots = MCPInitializeRootsParser.parseRoots(from: body)
        } else {
            identity = MCPClientIdentity()
            roots = []
        }
        MCPHTTPConnectionContextRegistry.shared.remember(
            sessionID: sessionID,
            context: MCPConnectionContext(
                transportKey: sessionID,
                mcpRoots: roots,
                clientIdentity: identity
            )
        )
    }

    private func closeSession(_ sessionID: String, reason: MCPTeardownReason = .shutdown) async {
        sessionRecoveryTasks[sessionID]?.cancel()
        sessionRecoveryTasks[sessionID] = nil
        if let onTransportTeardown {
            _ = await onTransportTeardown(sessionID, reason)
        }
        MCPHTTPConnectionContextRegistry.shared.remove(sessionID: sessionID)
        MCPRootsProviderRegistry.shared.remove(key: sessionID)
        MCPStickyAttributionRegistry.shared.remove(for: sessionID)
        openStreams[sessionID] = nil
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
        logger.info("Closed HTTP session", metadata: ["sessionID": "\(sessionID)", "reason": "\(reason.rawValue)"])
    }

    /// Closes every session concurrently and stops waiting at
    /// `shutdownDeadline`, so one wedged teardown cannot hold shutdown.
    private func closeAllSessions() async {
        for task in sessionRecoveryTasks.values {
            task.cancel()
        }
        sessionRecoveryTasks.removeAll()
        let sessionIDs = Array(sessions.keys)
        guard !sessionIDs.isEmpty else { return }
        let closers = sessionIDs.map { sessionID in
            Task { await self.closeSession(sessionID, reason: .shutdown) }
        }
        let allClosed = Task {
            for closer in closers { await closer.value }
        }
        let finished = await Self.awaitWithDeadline(allClosed, deadline: configuration.shutdownDeadline)
        if !finished {
            logger.warning(
                "HTTP shutdown deadline reached before every session closed",
                metadata: ["deadline": "\(configuration.shutdownDeadline)", "sessions": "\(sessionIDs.count)"]
            )
        }
    }

    /// True when `task` finished before `deadline`. Does not wait for the
    /// task past the deadline (a task group would).
    static func awaitWithDeadline(_ task: Task<Void, Never>, deadline: Duration) async -> Bool {
        let finished = Task { () -> Bool in
            await task.value
            return true
        }
        return await MCPDeadline.value(of: finished, within: deadline, orElse: false)
    }

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.sessionCleanupInterval)
            } catch {
                break
            }
            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout
            }
            for (sessionID, _) in expired {
                logger.info("HTTP session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID, reason: .idleExpiry)
            }
        }
    }
}

private func isInitializeRequest(_ body: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return false
    }
    return (json["method"] as? String) == "initialize"
}
#endif
