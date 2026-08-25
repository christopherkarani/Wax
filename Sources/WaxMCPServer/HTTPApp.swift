#if MCPServer
import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

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

        init(
            host: String = "127.0.0.1",
            port: Int = 3000,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            sessionCleanupInterval: Duration = .seconds(60),
            retryInterval: Int? = nil,
            maxRequestBodyBytes: Int = 1_048_576,
            authToken: String? = nil
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
            self.sessionCleanupInterval = sessionCleanupInterval
            self.retryInterval = retryInterval
            self.maxRequestBodyBytes = max(1, maxRequestBodyBytes)
            self.authToken = HTTPAuthPolicy.normalizedToken(authToken)
        }
    }

    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    /// In-flight recoveries keyed by client `Mcp-Session-Id` so concurrent stale
    /// tool calls wait for one recreate instead of racing.
    private var sessionRecoveryTasks: [String: Task<Bool, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?

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
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
        self.maxRequestBodyBytes = configuration.maxRequestBodyBytes
        self.logger = logger ?? Logger(
            label: "wax.mcp.http",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    var endpoint: String { configuration.endpoint }

    func boundPort() -> Int? {
        channel?.localAddress?.port
    }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
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

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if HTTPAuthPolicy.requiresAuthentication(host: configuration.host),
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
                sessions.removeValue(forKey: sessionID)
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

    private func isValidClientSessionID(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionID.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
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
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        do {
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return response
        } catch {
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
        sessionRecoveryTasks[sessionID] = nil
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

        do {
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

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )
            logger.info(
                "Recovered HTTP session after map miss",
                metadata: ["sessionID": "\(sessionID)"]
            )
            return true
        } catch {
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

    private func closeSession(_ sessionID: String) async {
        sessionRecoveryTasks[sessionID]?.cancel()
        sessionRecoveryTasks[sessionID] = nil
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
        logger.info("Closed HTTP session", metadata: ["sessionID": "\(sessionID)"])
    }

    private func closeAllSessions() async {
        for task in sessionRecoveryTasks.values {
            task.cancel()
        }
        sessionRecoveryTasks.removeAll()
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
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
                await closeSession(sessionID)
            }
        }
    }
}

enum HTTPAuthPolicy {
    static func requiresAuthentication(host rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch host {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return false
        default:
            return true
        }
    }

    static func normalizedToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isAuthorized(requestToken: String?, configuredToken: String?) -> Bool {
        guard let configuredToken = normalizedToken(configuredToken),
              let requestToken else {
            return false
        }
        let trimmed = requestToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Bearer "
        guard trimmed.hasPrefix(prefix) else { return false }
        return String(trimmed.dropFirst(prefix.count)) == configuredToken
    }
}

private func isInitializeRequest(_ body: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return false
    }
    return (json["method"] as? String) == "initialize"
}

enum HTTPRequestBodyLimit {
    static func exceedsLimit(
        currentBytes: Int,
        incomingBytes: Int,
        contentLength: Int?,
        maxBytes: Int
    ) -> Bool {
        if let contentLength, contentLength > maxBytes {
            return true
        }
        guard incomingBytes <= maxBytes else { return true }
        return currentBytes > maxBytes - incomingBytes
    }
}

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: MCPHTTPApplication

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
        var exceededBodyLimit: Bool = false
    }

    private var requestState: RequestState?
    private var channelContext: ChannelHandlerContext?

    init(app: MCPHTTPApplication) {
        self.app = app
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channelContext = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if channelContext === context {
            channelContext = nil
        }
        requestState = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestState = nil
        if channelContext === context {
            channelContext = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        requestState = nil
        closeIfActive(context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            let contentLength = head.headers.first(name: "content-length").flatMap(Int.init)
            if HTTPRequestBodyLimit.exceedsLimit(
                currentBytes: 0,
                incomingBytes: 0,
                contentLength: contentLength,
                maxBytes: app.maxRequestBodyBytes
            ) {
                requestState = nil
                writePayloadTooLarge(version: head.version, context: context)
                return
            }
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            guard var state = requestState else { return }
            if state.exceededBodyLimit || HTTPRequestBodyLimit.exceedsLimit(
                currentBytes: state.bodyBuffer.readableBytes,
                incomingBytes: buffer.readableBytes,
                contentLength: nil,
                maxBytes: app.maxRequestBodyBytes
            ) {
                requestState = nil
                writePayloadTooLarge(version: state.head.version, context: context)
                return
            }
            state.bodyBuffer.writeBuffer(&buffer)
            requestState = state
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            let version = state.head.version
            let path = state.head.uri.split(separator: "?").first.map(String.init) ?? state.head.uri
            let exceededBodyLimit = state.exceededBodyLimit
            let request = makeHTTPRequest(from: state)
            let eventLoop = context.eventLoop
            Task {
                let response = await self.completeRequest(
                    path: path,
                    exceededBodyLimit: exceededBodyLimit,
                    request: request
                )
                await self.writeResponse(response, version: version, eventLoop: eventLoop)
            }
        }
    }

    private func writePayloadTooLarge(version: HTTPVersion, context: ChannelHandlerContext) {
        let response = HTTPResponse.error(statusCode: 413, .invalidRequest("Payload Too Large"))
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode))
        for (name, value) in response.headers {
            head.headers.add(name: name, value: value)
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let bodyData = response.bodyData {
            var body = context.channel.allocator.buffer(capacity: bodyData.count)
            body.writeBytes(bodyData)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        closeIfActive(context)
    }

    private func completeRequest(
        path: String,
        exceededBodyLimit: Bool,
        request: HTTPRequest
    ) async -> HTTPResponse {
        let endpoint = await app.endpoint

        if exceededBodyLimit {
            return .error(statusCode: 413, .invalidRequest("Payload Too Large"))
        }

        guard path == endpoint else {
            return .error(statusCode: 404, .invalidRequest("Not Found"))
        }

        return await app.handleHTTPRequest(request)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes) {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(method: state.head.method.rawValue, headers: headers, body: body, path: path)
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        eventLoop: EventLoop
    ) async {
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            await hop(eventLoop) {
                self.writeHeadAndFlush(statusCode: statusCode, headers: headers, version: version)
            }

            do {
                for try await chunk in stream {
                    await hop(eventLoop) {
                        self.writeBodyChunk(chunk)
                    }
                }
            } catch {
                await hop(eventLoop) {
                    self.closeActiveChannel()
                }
                return
            }

            await hop(eventLoop) {
                self.writeEnd()
            }

        default:
            let bodyData = response.bodyData
            await hop(eventLoop) {
                self.writeCompleteResponse(
                    statusCode: statusCode,
                    headers: headers,
                    version: version,
                    bodyData: bodyData
                )
            }
        }
    }

    private func hop(_ eventLoop: EventLoop, _ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventLoop.execute {
                body()
                continuation.resume()
            }
        }
    }

    private func writeHeadAndFlush(statusCode: Int, headers: [String: String], version: HTTPVersion) {
        guard let context = activeContext() else { return }
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.flush()
    }

    private func writeBodyChunk(_ chunk: Data) {
        guard let context = activeContext() else { return }
        var buffer = context.channel.allocator.buffer(capacity: chunk.count)
        buffer.writeBytes(chunk)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func writeEnd() {
        guard let context = activeContext() else { return }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        closeIfActive(context)
    }

    private func writeCompleteResponse(
        statusCode: Int,
        headers: [String: String],
        version: HTTPVersion,
        bodyData: Data?
    ) {
        guard let context = activeContext() else { return }
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body = bodyData {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        closeIfActive(context)
    }

    private func activeContext() -> ChannelHandlerContext? {
        guard let context = channelContext, context.channel.isActive else { return nil }
        return context
    }

    private func closeActiveChannel() {
        guard let context = activeContext() else { return }
        closeIfActive(context)
    }

    private func closeIfActive(_ context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        context.close(promise: nil)
    }
}
#endif
