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

enum MCPHTTPServerPipeline {
    static func configure(_ channel: Channel, app: MCPHTTPApplication) -> EventLoopFuture<Void> {
        // The pipeline handler stops reading while an SSE response is open.
        // A client reset is then invisible and the accepted socket stays in
        // TCP CLOSED with its fd held. The watcher polls that socket and
        // closes the channel. It does not read into the pipeline: those
        // bytes would sit in the handler's buffer until the response ended.
        channel.pipeline.addHandler(MCPHTTPPeerCloseWatch(), position: .first).flatMap {
            channel.pipeline.configureHTTPServerPipeline()
        }.flatMap {
            channel.pipeline.addHandler(HTTPHandler(app: app))
        }
    }
}

enum MCPHTTPPeerReset {
    /// Hangup, reset, or any inbound byte. Inbound bytes are not delivered:
    /// the HTTP pipeline is paused for the open SSE response, and reading
    /// them here would store them without a bound.
    static func shouldClose(_ handle: NIOBSDSocket.Handle) -> Bool {
        var pollFD = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 0)
        guard ready > 0 else { return false }
        let events = Int32(pollFD.revents)
        if events & (POLLHUP | POLLERR | POLLNVAL) != 0 {
            return true
        }
        guard events & Int32(POLLIN) != 0 else { return false }
        var byte: UInt8 = 0
        let peeked = recv(handle, &byte, 1, Int32(MSG_PEEK))
        if peeked == 0 || peeked > 0 { return true }
        let error = errno
        if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return false }
        return error == ECONNRESET || error == EPIPE || error == ENOTCONN
            || error == ECONNABORTED || error == ETIMEDOUT
    }
}

final class MCPHTTPPeerCloseWatch: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var pump: RepeatedTask?
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        disarm()
        if self.context === context {
            self.context = nil
        }
    }

    func arm() {
        guard pump == nil, let context else { return }
        pump = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .milliseconds(50),
            delay: .milliseconds(50)
        ) { [weak self] _ in
            self?.closeIfPeerGone()
        }
    }

    func disarm() {
        pump?.cancel()
        pump = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        disarm()
        self.context = nil
        context.fireChannelInactive()
    }

    private func closeIfPeerGone() {
        guard let context, context.channel.isActive else { return }
        let gone: Bool
        do {
            gone = try context.channel.pipeline.syncOperations.withUnsafeTransportIfAvailable(
                of: NIOBSDSocket.Handle.self
            ) { handle in
                MCPHTTPPeerReset.shouldClose(handle)
            } ?? false
        } catch {
            return
        }
        if gone {
            context.close(promise: nil)
        }
    }
}

private final class HopResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func succeed() {
        take()?.resume()
    }

    deinit {
        guard let pending = take() else { return }
        // NIO can drop the scheduled callback while this object is still
        // inside withCheckedContinuation. Resume on a follow-up turn.
        Task { pending.resume() }
    }

    private func take() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        return pending
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
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A dropped GET is one HTTP connection. The MCP session stays up so
        // the client's next POST still finds it. DELETE and idle expiry close it.
        channelContext = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
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
                await self.writeResponse(
                    response,
                    version: version,
                    eventLoop: eventLoop,
                    request: request
                )
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
        eventLoop: EventLoop,
        request: HTTPRequest
    ) async {
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            let method = request.method
            await hop(eventLoop) {
                if method.uppercased() == "GET" {
                    self.armPeerCloseWatch()
                }
                self.writeHeadAndFlush(statusCode: statusCode, headers: headers, version: version)
            }

            do {
                for try await chunk in stream {
                    await hop(eventLoop) {
                        self.writeBodyChunk(chunk)
                    }
                }
            } catch {
                // The peer watcher closes the channel. Finish the write if it is still open.
            }

            await hop(eventLoop) {
                self.disarmPeerCloseWatch()
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

    private func armPeerCloseWatch() {
        guard let context = channelContext,
              let watch = try? context.pipeline.syncOperations.context(
                handlerType: MCPHTTPPeerCloseWatch.self
              ).handler as? MCPHTTPPeerCloseWatch
        else { return }
        watch.arm()
    }

    private func disarmPeerCloseWatch() {
        guard let context = channelContext,
              let watch = try? context.pipeline.syncOperations.context(
                handlerType: MCPHTTPPeerCloseWatch.self
              ).handler as? MCPHTTPPeerCloseWatch
        else { return }
        watch.disarm()
    }

    private func hop(_ eventLoop: EventLoop, _ body: @escaping @Sendable () -> Void) async {
        if eventLoop.inEventLoop {
            body()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // If the loop is already shut down, NIO drops this callback.
            // HopResume resumes from deinit so the waiter is not stranded.
            let resume = HopResume(continuation)
            eventLoop.execute {
                body()
                resume.succeed()
            }
        }
    }

    private func writeHeadAndFlush(statusCode: Int, headers: [String: String], version: HTTPVersion) {
        guard let context = channelContext else { return }
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.flush()
    }

    private func writeBodyChunk(_ chunk: Data) {
        guard let context = channelContext else { return }
        var buffer = context.channel.allocator.buffer(capacity: chunk.count)
        buffer.writeBytes(chunk)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func writeEnd() {
        guard let context = channelContext else { return }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func writeCompleteResponse(
        statusCode: Int,
        headers: [String: String],
        version: HTTPVersion,
        bodyData: Data?
    ) {
        guard let context = channelContext else { return }
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
    }
}
#endif
