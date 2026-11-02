#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

private func initializeRequest(sessionID: String? = nil) throws -> HTTPRequest {
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "wax-http-hardening", "version": "1.0"],
        ],
    ])
    var headers = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Host": "127.0.0.1:3000",
    ]
    if let sessionID {
        headers[HTTPHeaderName.sessionID] = sessionID
    }
    return HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
}

private func toolsListRequest(sessionID: String) -> HTTPRequest {
    HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Host": "127.0.0.1:3000",
            HTTPHeaderName.sessionID: sessionID,
        ],
        body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
        path: "/mcp"
    )
}

private func makeTestServer() -> Server {
    Server(name: "wax-mcp", version: "test", capabilities: .init(tools: .init(listChanged: false)))
}

private final class TeardownProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var reasons: [String: MCPTeardownReason] = [:]
    private(set) var finished = 0

    func begin(_ key: String, _ reason: MCPTeardownReason) {
        lock.lock()
        defer { lock.unlock() }
        reasons[key] = reason
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
        finished += 1
    }

    func snapshot() -> (maxInFlight: Int, reasons: [String: MCPTeardownReason], finished: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (maxInFlight, reasons, finished)
    }
}

@Test
func httpSessionCapEvictsLeastRecentlyUsedSession() async throws {
    let probe = TeardownProbe()
    let app = MCPHTTPApplication(
        configuration: .init(maxSessions: 2),
        onTransportTeardown: { key, reason in
            probe.begin(key, reason)
            probe.end()
            return .skipped("test")
        },
        serverFactory: { _, _ in makeTestServer() }
    )

    var created: [String] = []
    for _ in 0..<3 {
        let response = await app.handleHTTPRequest(try initializeRequest())
        #expect(response.statusCode == 200)
        created.append(try #require(response.headers[HTTPHeaderName.sessionID]))
    }

    let live = await app.liveSessionIDs()
    #expect(live.count == 2)
    #expect(!live.contains(created[0]))
    #expect(live.contains(created[1]))
    #expect(live.contains(created[2]))
    #expect(probe.snapshot().reasons[created[0]] == .capacityEviction)
    await app.stop()
}

@Test
func httpRejectsOversizedClientSessionIDs() async throws {
    let app = MCPHTTPApplication(serverFactory: { _, _ in makeTestServer() })
    let oversized = String(repeating: "a", count: MCPHTTPApplication.maxClientSessionIDBytes + 1)

    let initialized = await app.handleHTTPRequest(try initializeRequest(sessionID: oversized))
    #expect(initialized.statusCode == 200)
    let assigned = try #require(initialized.headers[HTTPHeaderName.sessionID])
    #expect(assigned != oversized)
    #expect(!(await app.liveSessionIDs().contains(oversized)))

    let recovered = await app.handleHTTPRequest(toolsListRequest(sessionID: oversized))
    #expect(recovered.statusCode == 400)
    #expect(!(await app.liveSessionIDs().contains(oversized)))

    let maxLength = String(repeating: "b", count: MCPHTTPApplication.maxClientSessionIDBytes)
    let accepted = await app.handleHTTPRequest(try initializeRequest(sessionID: maxLength))
    #expect(accepted.headers[HTTPHeaderName.sessionID] == maxLength)
    await app.stop()
}

@Test
func bearerTokenComparisonKeepsEqualitySemantics() {
    #expect(HTTPAuthPolicy.constantTimeEquals("secret-token", "secret-token"))
    #expect(HTTPAuthPolicy.constantTimeEquals("", ""))
    #expect(!HTTPAuthPolicy.constantTimeEquals("secret-token", "secret-tokeN"))
    #expect(!HTTPAuthPolicy.constantTimeEquals("secret-token", "secret-token-longer"))
    #expect(!HTTPAuthPolicy.constantTimeEquals("secret", "secret-token"))
    #expect(!HTTPAuthPolicy.constantTimeEquals("", "secret-token"))
    #expect(!HTTPAuthPolicy.constantTimeEquals("sécret", "secret"))

    #expect(HTTPAuthPolicy.isAuthorized(requestToken: "Bearer secret-token", configuredToken: "secret-token"))
    #expect(!HTTPAuthPolicy.isAuthorized(requestToken: "Bearer secret-toke", configuredToken: "secret-token"))
    #expect(!HTTPAuthPolicy.isAuthorized(requestToken: "Bearer secret-token2", configuredToken: "secret-token"))
}

@Test
func httpShutdownClosesSessionsConcurrently() async throws {
    let probe = TeardownProbe()
    let app = MCPHTTPApplication(
        onTransportTeardown: { key, reason in
            probe.begin(key, reason)
            try? await Task.sleep(for: .milliseconds(300))
            probe.end()
            return .skipped("test")
        },
        serverFactory: { _, _ in makeTestServer() }
    )
    for _ in 0..<3 {
        let response = await app.handleHTTPRequest(try initializeRequest())
        #expect(response.statusCode == 200)
    }

    await app.stop()

    let snapshot = probe.snapshot()
    #expect(snapshot.reasons.count == 3)
    #expect(snapshot.reasons.values.allSatisfy { $0 == .shutdown })
    // Sequential teardown never overlaps; concurrent teardown must.
    #expect(snapshot.maxInFlight > 1)
}

@Test
func httpShutdownStopsWaitingAtDeadline() async throws {
    let probe = TeardownProbe()
    let app = MCPHTTPApplication(
        configuration: .init(shutdownDeadline: .milliseconds(100)),
        onTransportTeardown: { key, reason in
            probe.begin(key, reason)
            // A wedged teardown that ignores cancellation.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
            }
            probe.end()
            return .skipped("test")
        },
        serverFactory: { _, _ in makeTestServer() }
    )
    let response = await app.handleHTTPRequest(try initializeRequest())
    #expect(response.statusCode == 200)

    await app.stop()

    let snapshot = probe.snapshot()
    #expect(snapshot.reasons.count == 1)
    #expect(snapshot.finished == 0)
}

@Test
func shutdownSignalLatchForcesExitOnSecondSignal() {
    let latch = MCPShutdownSignalLatch()
    #expect(latch.record() == .graceful)
    #expect(latch.record() == .forceExit)
    #expect(latch.record() == .forceExit)
}

@Test
func teardownPerformErrorIsReportedAsFailureNotTimeout() async {
    struct BrokerDown: Error {}
    let outcome = await MCPTransportTeardown.closeExactly(
        sessionID: UUID(),
        reason: .shutdown,
        perform: { _ in throw BrokerDown() }
    )
    #expect(outcome.status == "failed")
    #expect(outcome.reason.contains("BrokerDown"))
}

private func errorPayload(_ result: CallTool.Result) -> [String: Any] {
    guard case .text(let text, _, _)? = result.content.first,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

@Test
func brokerUnresponsiveIsMappedFromTypedErrorNotMessageText() async {
    let typed = await WaxMCPTools.executeCall(
        params: .init(name: "stats", arguments: [:]),
        structuredMemoryEnabled: true,
        sessionHint: nil,
        pathConfinement: nil
    ) { _ in
        throw BrokerUnresponsiveError("socket accepted but never answered")
    }
    #expect(errorPayload(typed)["code"] as? String == "broker_unresponsive")

    struct LookalikeError: LocalizedError {
        var errorDescription: String? { "peer did not answer (socket_live=true)" }
    }
    let lookalike = await WaxMCPTools.executeCall(
        params: .init(name: "stats", arguments: [:]),
        structuredMemoryEnabled: true,
        sessionHint: nil,
        pathConfinement: nil
    ) { _ in
        throw LookalikeError()
    }
    #expect(errorPayload(lookalike)["code"] as? String == "execution_failed")
}

@Test
func brokerFailureCodesComeFromPayloadNotMessageText() async {
    let mustWithoutCode = await WaxMCPTools.executeCall(
        params: .init(name: "stats", arguments: [:]),
        structuredMemoryEnabled: true,
        sessionHint: nil,
        pathConfinement: nil
    ) { request in
        AgentBrokerResponse.failure(id: request.id, message: "store must be repaired before use")
    }
    #expect(errorPayload(mustWithoutCode)["code"] as? String == "execution_failed")

    let typedValidation = await WaxMCPTools.executeCall(
        params: .init(name: "stats", arguments: [:]),
        structuredMemoryEnabled: true,
        sessionHint: nil,
        pathConfinement: nil
    ) { request in
        let error = BrokerValidationError.invalid("limit is out of range")
        return AgentBrokerResponse.failure(id: request.id, payload: error.brokerPayload, message: error.localizedDescription)
    }
    #expect(errorPayload(typedValidation)["code"] as? String == "invalid_arguments")
}

@Test
func brokerValidationFailuresCarryInvalidArgumentsCode() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-typed-errors-\(UUID().uuidString)", isDirectory: true)
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

    let missing = await broker.handle(.init(command: "remember", arguments: [:]))
    #expect(!missing.ok)
    #expect(missing.payload?.objectValue?["code"]?.stringValue == "invalid_arguments")
}
#endif
