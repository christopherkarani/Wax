#if MCPServer
import Foundation
import MCP
import NIOCore
import NIOPosix
import Testing
@testable import wax_mcp

#if canImport(Darwin)
import Darwin
#endif

@Test(.timeLimit(.minutes(1)))
func abortedGETStreamDoesNotLeaveClosedSockets() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(
            host: "127.0.0.1",
            port: 0,
            endpoint: "/mcp",
            sessionTimeout: 30
        ),
        serverFactory: { _, _ in
            Server(
                name: "wax-http-leak",
                version: "0",
                capabilities: .init(tools: .init(listChanged: false))
            )
        }
    )
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            MCPHTTPServerPipeline.configure(channel, app: app)
        }
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .bind(host: "127.0.0.1", port: 0)
        .get()
    defer {
        try? await server.close()
        try? await group.shutdownGracefully()
    }
    let port = try #require(server.localAddress?.port)

    let sessionID = try initializeMCPSession(port: port)
    #expect(try connectedSockets(port: port) == 0)

    for _ in 0..<6 {
        try abortGETStream(port: port, sessionID: sessionID)
    }
    try await Task.sleep(for: .milliseconds(900))

    let lingering = try connectedSockets(port: port)
    #expect(lingering == 0, "aborted GET left \(lingering) sockets on port \(port)")
}

@Test(.timeLimit(.minutes(1)))
func abortedGETStreamDoesNotCloseTheMCPSession() async throws {
    let teardown = TeardownLog()
    let app = MCPHTTPApplication(
        configuration: .init(
            host: "127.0.0.1",
            port: 0,
            endpoint: "/mcp",
            sessionTimeout: 30
        ),
        onTransportTeardown: { _, _ in
            await teardown.record()
            return .skipped("test")
        },
        serverFactory: { _, _ in
            Server(
                name: "wax-http-leak",
                version: "0",
                capabilities: .init(tools: .init(listChanged: false))
            )
        }
    )
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            MCPHTTPServerPipeline.configure(channel, app: app)
        }
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .bind(host: "127.0.0.1", port: 0)
        .get()
    defer {
        try? await server.close()
        try? await group.shutdownGracefully()
    }
    let port = try #require(server.localAddress?.port)
    let sessionID = try initializeMCPSession(port: port)

    try abortGETStream(port: port, sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(900))

    #expect(await teardown.snapshot() == 0)
    #expect(try connectedSockets(port: port) == 0)

    let followUp = try postJSON(
        port: port,
        sessionID: sessionID,
        body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
    )
    #expect(followUp.hasPrefix("HTTP/1.1 200"), "dropped GET ended the session: \(followUp.prefix(180))")
}

@Test(.timeLimit(.minutes(1)))
func abortedGETWithUnreadBytesDoesNotLeaveClosedSockets() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(
            host: "127.0.0.1",
            port: 0,
            endpoint: "/mcp",
            sessionTimeout: 30
        ),
        serverFactory: { _, _ in
            Server(
                name: "wax-http-leak",
                version: "0",
                capabilities: .init(tools: .init(listChanged: false))
            )
        }
    )
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            MCPHTTPServerPipeline.configure(channel, app: app)
        }
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .bind(host: "127.0.0.1", port: 0)
        .get()
    defer {
        try? await server.close()
        try? await group.shutdownGracefully()
    }
    let port = try #require(server.localAddress?.port)
    let sessionID = try initializeMCPSession(port: port)

    try abortGETStream(port: port, sessionID: sessionID, extraBytes: 65_536)
    try await Task.sleep(for: .milliseconds(900))

    let lingering = try connectedSockets(port: port)
    #expect(lingering == 0, "aborted GET with unread bytes left \(lingering) sockets on port \(port)")
}

private actor TeardownLog {
    private var count = 0

    func record() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

private func initializeMCPSession(port: Int) throws -> String {
    let body = Data(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"leak-test","version":"0"}}}"#
            .utf8
    )
    let fd = try connectLoopback(port)
    defer { close(fd) }
    try sendHTTP(
        fd: fd,
        header: """
        POST /mcp HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Type: application/json\r
        Accept: application/json, text/event-stream\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
    )
    try writeAll(fd: fd, bytes: [UInt8](body))
    let response = try readAvailable(fd: fd, timeout: .seconds(3))
    let text = String(decoding: response, as: UTF8.self)
    let prefix = "MCP-Session-Id:"
    for line in text.split(separator: "\r\n", omittingEmptySubsequences: false) {
        if line.lowercased().hasPrefix(prefix.lowercased()) {
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                return String(value)
            }
        }
    }
    Issue.record("initialize response had no session id: \(text.prefix(400))")
    throw HTTPLeakTestError.noSession
}

private func abortGETStream(port: Int, sessionID: String, extraBytes: Int = 0) throws {
    let fd = try connectLoopback(port)
    try sendHTTP(
        fd: fd,
        header: """
        GET /mcp HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Accept: text/event-stream\r
        MCP-Session-Id: \(sessionID)\r
        Connection: keep-alive\r
        \r

        """
    )
    _ = try readAvailable(fd: fd, timeout: .milliseconds(800))
    if extraBytes > 0 {
        try writeAll(fd: fd, bytes: [UInt8](repeating: 0x61, count: extraBytes))
    }
    var lingerValue = linger(l_onoff: 1, l_linger: 0)
    _ = withUnsafePointer(to: &lingerValue) {
        setsockopt(fd, SOL_SOCKET, SO_LINGER, $0, socklen_t(MemoryLayout<linger>.size))
    }
    close(fd)
}

private func postJSON(port: Int, sessionID: String, body: Data) throws -> String {
    let fd = try connectLoopback(port)
    defer { close(fd) }
    try sendHTTP(
        fd: fd,
        header: """
        POST /mcp HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Type: application/json\r
        Accept: application/json, text/event-stream\r
        MCP-Session-Id: \(sessionID)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
    )
    try writeAll(fd: fd, bytes: [UInt8](body))
    let response = try readAvailable(fd: fd, timeout: .seconds(3))
    return String(decoding: response, as: UTF8.self)
}

private func connectedSockets(port: Int) throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-n", "-P", "-p", String(getpid())]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    let marker = ":\(port)->"
    return text.split(separator: "\n").filter { line in
        line.contains(marker) || line.contains(":\(port) ")
    }.filter { line in
        !line.contains("(LISTEN)")
    }.count
}

private func connectLoopback(_ port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HTTPLeakTestError.socket }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        throw HTTPLeakTestError.connect
    }
    return fd
}

private func sendHTTP(fd: Int32, header: String) throws {
    try writeAll(fd: fd, bytes: Array(header.utf8))
}

private func writeAll(fd: Int32, bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
        let wrote = bytes[offset...].withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        if wrote < 0 {
            throw HTTPLeakTestError.write
        }
        offset += wrote
    }
}

private func readAvailable(fd: Int32, timeout: Duration) throws -> [UInt8] {
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let milliseconds = Int32((timeout.components.seconds * 1_000) + (timeout.components.attoseconds / 1_000_000_000_000_000))
    let ready = poll(&pollFD, 1, max(milliseconds, 1))
    guard ready > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: 8192)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { return [] }
    return Array(buffer.prefix(count))
}

private enum HTTPLeakTestError: Error {
    case socket
    case connect
    case write
    case noSession
}
#endif
