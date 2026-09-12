#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

@Test
func transportTeardownIsIdempotentAndExact() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-teardown-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let broker = try await AgentBrokerService(
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    defer { Task { try? await broker.close() } }

    let opened = await broker.handle(
        AgentBrokerRequest(
            command: "session_open",
            arguments: [
                "project": .string("teardown"),
                "conversation_id": .string("transport:teardown-1"),
            ]
        )
    )
    let sessionID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue)
    MCPBoundSessionRegistry.shared.remember(key: "http-session-1", sessionID: sessionID, ownership: .transport)

    let first = await MCPTransportTeardown.checkpointBoundTransportSession(
        connectionKey: "http-session-1",
        reason: .httpDelete,
        perform: { request in await broker.handle(request) }
    )
    #expect(first.status == "closed")
    #expect(MCPBoundSessionRegistry.shared.current(for: "http-session-1") == nil)

    MCPBoundSessionRegistry.shared.remember(key: "http-session-1", sessionID: sessionID, ownership: .transport)
    let second = await MCPTransportTeardown.checkpointBoundTransportSession(
        connectionKey: "http-session-1",
        reason: .httpDelete,
        perform: { request in await broker.handle(request) }
    )
    #expect(second.alreadyEnded || second.status == "closed")
    #expect(MCPBoundSessionRegistry.shared.current(for: "http-session-1") == nil)
}

@Test
func missingBindingSkipsTeardown() async {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }
    let outcome = await MCPTransportTeardown.checkpointBoundTransportSession(
        connectionKey: "missing",
        reason: .shutdown,
        perform: { _ in
            Issue.record("teardown must not call the broker without a binding")
            struct UnexpectedTeardown: Error {}
            throw UnexpectedTeardown()
        }
    )
    #expect(outcome.status == "skipped")
    #expect(outcome.reason == "no_bound_session")
}

@Test
func harvestTimeoutDoesNotThrowIntoHTTPPath() async {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }
    MCPBoundSessionRegistry.shared.remember(key: "slow", sessionID: UUID().uuidString, ownership: .transport)
    let outcome = await MCPTransportTeardown.checkpointBoundTransportSession(
        connectionKey: "slow",
        reason: .idleExpiry,
        perform: { _ in
            try await Task.sleep(for: .seconds(5))
            return AgentBrokerResponse(outcome: .success(payload: .object([:])), shouldExit: false)
        },
        timeoutSeconds: 0.05
    )
    #expect(outcome.status == "timeout")
}

@Test
func httpDeleteInvokesTeardownWithoutChangingStatus() async throws {
    let reasons = TeardownReasonBox()
    let initializeBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "wax-teardown-http", "version": "1.0"],
        ],
    ])
    let app = MCPHTTPApplication(
        onTransportTeardown: { _, reason in
            reasons.append(reason)
            return MCPTeardownOutcome(status: "closed", reason: reason.rawValue, alreadyEnded: false, sessionID: nil)
        },
        serverFactory: { _, _ in
            Server(name: "wax-mcp", version: "test", capabilities: .init(tools: .init(listChanged: false)))
        }
    )
    let initialized = await app.handleHTTPRequest(HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Host": "127.0.0.1:3000",
        ],
        body: initializeBody,
        path: "/mcp"
    ))
    #expect(initialized.statusCode == 200)
    let sessionID = try #require(initialized.headers[HTTPHeaderName.sessionID])
    let stored = MCPHTTPConnectionContextRegistry.shared.current(sessionID: sessionID)
    #expect(stored?.clientIdentity.name == "wax-teardown-http")
    #expect(stored?.clientIdentity.isSyntheticRecovery == false)

    let closed = await app.handleHTTPRequest(HTTPRequest(
        method: "DELETE",
        headers: [
            "Host": "127.0.0.1:3000",
            HTTPHeaderName.sessionID: sessionID,
        ],
        path: "/mcp"
    ))
    #expect(closed.statusCode == 200)
    #expect(reasons.snapshot() == [.httpDelete])
}

private final class TeardownReasonBox: @unchecked Sendable {
    private var reasons: [MCPTeardownReason] = []
    private let lock = NSLock()

    func append(_ reason: MCPTeardownReason) {
        lock.lock()
        reasons.append(reason)
        lock.unlock()
    }

    func snapshot() -> [MCPTeardownReason] {
        lock.lock()
        defer { lock.unlock() }
        return reasons
    }
}
#endif
