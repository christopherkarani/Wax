#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

@Suite(.serialized)
struct MCPAutoSessionCoordinatorTests {
    @Test
    func concurrentFirstRememberCallsShareOneSession() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withAutoSessionBroker { broker in
            let repo = try makeAutoSessionRepo(named: "concurrent-open")
            defer { try? FileManager.default.removeItem(at: repo) }
            let key = "auto-concurrent"
            let hint = MCPClientSessionHint(
                connectionKey: key,
                context: MCPConnectionContext(transportKey: key, advertisedCWD: repo.path)
            )

            async let first = WaxMCPTools.handleCall(
                params: .init(
                    name: "remember",
                    arguments: [
                        "content": .string("first concurrent auto-session write"),
                        "memory_type": .string("lesson"),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: hint
            )
            async let second = WaxMCPTools.handleCall(
                params: .init(
                    name: "remember",
                    arguments: [
                        "content": .string("second concurrent auto-session write"),
                        "memory_type": .string("fact"),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: hint
            )
            let results = await [first, second]
            #expect(results.allSatisfy { $0.isError != true })
            let sessionID = try #require(hint.current())
            let payloads = try results.map(requireAutoJSON)
            #expect(Set(payloads.compactMap { $0["session_id"] as? String }) == [sessionID])
            #expect(hint.currentOwnership() == .transport)
        }
    }

    @Test
    func statsNeverAutoOpensASession() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withAutoSessionBroker { broker in
            let hint = MCPClientSessionHint(
                connectionKey: "auto-stats",
                context: MCPConnectionContext(transportKey: "auto-stats")
            )
            let result = await WaxMCPTools.handleCall(
                params: .init(name: "stats", arguments: [:]),
                broker: broker,
                sessionHint: hint
            )
            #expect(result.isError != true)
            #expect(hint.current() == nil)
        }
    }

    @Test
    func twoTransportKeysDoNotShareWorkingMemory() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withAutoSessionBroker { broker in
            let repo = try makeAutoSessionRepo(named: "isolate-work")
            defer { try? FileManager.default.removeItem(at: repo) }
            let a = MCPClientSessionHint(
                connectionKey: "transport-a",
                context: MCPConnectionContext(transportKey: "transport-a", advertisedCWD: repo.path)
            )
            let b = MCPClientSessionHint(
                connectionKey: "transport-b",
                context: MCPConnectionContext(transportKey: "transport-b", advertisedCWD: repo.path)
            )
            let marker = "WORKING-ISOLATION-\(UUID().uuidString)"
            let wrote = await WaxMCPTools.handleCall(
                params: .init(
                    name: "remember",
                    arguments: [
                        "content": .string(marker),
                        "memory_type": .string("task_state"),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: a
            )
            #expect(wrote.isError != true)
            #expect(a.current() != b.current() || b.current() == nil)

            let recalled = await WaxMCPTools.handleCall(
                params: .init(
                    name: "recall",
                    arguments: [
                        "query": .string(marker),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: b
            )
            #expect(recalled.isError != true)
            let payload = try requireAutoJSON(recalled)
            // task_state is session-local: transport B must never see A's marker.
            // (The response echoes the query string, so assert on results, not the body.)
            let hits = payload["results"] as? [[String: Any]] ?? []
            #expect(hits.allSatisfy { ($0["text"] as? String)?.contains(marker) != true })
            #expect(a.current() != nil)
            #expect(b.current() != nil)
            #expect(a.current() != b.current())
        }
    }

    @Test
    func explicitHostConversationIDsStayDistinct() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withAutoSessionBroker { broker in
            let repo = try makeAutoSessionRepo(named: "host-ids")
            defer { try? FileManager.default.removeItem(at: repo) }
            let first = MCPClientSessionHint(
                connectionKey: "host-one",
                context: MCPConnectionContext(
                    transportKey: "host-one",
                    advertisedCWD: repo.path,
                    clientIdentity: MCPClientIdentity(name: "cursor", version: "1"),
                    trustedHostConversation: HostConversationKey(
                        hostNamespace: "cursor",
                        conversationID: "chat-a"
                    )
                )
            )
            let second = MCPClientSessionHint(
                connectionKey: "host-two",
                context: MCPConnectionContext(
                    transportKey: "host-two",
                    advertisedCWD: repo.path,
                    clientIdentity: MCPClientIdentity(name: "cursor", version: "1"),
                    trustedHostConversation: HostConversationKey(
                        hostNamespace: "cursor",
                        conversationID: "chat-b"
                    )
                )
            )
            for hint in [first, second] {
                let result = await WaxMCPTools.handleCall(
                    params: .init(
                        name: "remember",
                        arguments: [
                            "content": .string("host conversation isolation"),
                            "memory_type": .string("lesson"),
                            "cwd": .string(repo.path),
                        ]
                    ),
                    broker: broker,
                    sessionHint: hint
                )
                #expect(result.isError != true)
            }
            #expect(first.current() != second.current())
            #expect(first.currentOwnership() == .host)
            #expect(second.currentOwnership() == .host)
        }
    }

    @Test
    func sameTransportKeyRecoversBinding() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withAutoSessionBroker { broker in
            let repo = try makeAutoSessionRepo(named: "reconnect")
            defer { try? FileManager.default.removeItem(at: repo) }
            let first = MCPClientSessionHint(
                connectionKey: "mcp-session-same",
                context: MCPConnectionContext(transportKey: "mcp-session-same", advertisedCWD: repo.path)
            )
            let wrote = await WaxMCPTools.handleCall(
                params: .init(
                    name: "remember",
                    arguments: [
                        "content": .string("reconnect binding survives server recreate"),
                        "memory_type": .string("lesson"),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: first
            )
            #expect(wrote.isError != true)
            let sessionID = try #require(first.current())
            let recreated = MCPClientSessionHint(
                connectionKey: "mcp-session-same",
                context: MCPConnectionContext(transportKey: "mcp-session-same", advertisedCWD: repo.path)
            )
            #expect(recreated.current() == sessionID)
        }
    }

    @Test
    func staleBindingRetriesInactiveSessionOnce() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        try await withAutoSessionBroker { broker in
            let repo = try makeAutoSessionRepo(named: "stale-retry")
            defer { try? FileManager.default.removeItem(at: repo) }
            let hint = MCPClientSessionHint(
                connectionKey: "stale-bind",
                context: MCPConnectionContext(transportKey: "stale-bind", advertisedCWD: repo.path)
            )
            let opened = await WaxMCPTools.handleCall(
                params: .init(
                    name: "remember",
                    arguments: [
                        "content": .string("initial bind"),
                        "memory_type": .string("lesson"),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: hint
            )
            #expect(opened.isError != true)
            let staleID = try #require(hint.current())
            let closed = await WaxMCPTools.handleCall(
                params: .init(
                    name: "session_close",
                    arguments: [
                        "session_id": .string(staleID),
                        "content": .string("out of band close"),
                    ]
                ),
                broker: broker,
                sessionHint: hint
            )
            #expect(closed.isError != true)
            hint.bind(staleID, ownership: .transport)
            MCPBoundSessionRegistry.shared.remember(key: "stale-bind", sessionID: staleID, ownership: .transport)

            let retried = await WaxMCPTools.handleCall(
                params: .init(
                    name: "remember",
                    arguments: [
                        "content": .string("retry after stale bind"),
                        "memory_type": .string("lesson"),
                        "cwd": .string(repo.path),
                    ]
                ),
                broker: broker,
                sessionHint: hint
            )
            #expect(retried.isError != true)
            let payload = try requireAutoJSON(retried)
            #expect(payload["committed"] as? Bool == true)
            #expect(hint.current() != staleID)
        }
    }

    @Test
    func killSwitchRestoresExplicitOpen() async throws {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        #expect(!MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "0"]))
    }

    @Test
    func reverseInvalidationClearsEveryKeyForBrokerUUID() {
        MCPBoundSessionRegistry.shared.resetForTests()
        defer { MCPBoundSessionRegistry.shared.resetForTests() }
        MCPBoundSessionRegistry.shared.remember(key: "k1", sessionID: "SID-1", ownership: .transport)
        MCPBoundSessionRegistry.shared.remember(key: "k2", sessionID: "SID-1", ownership: .transport)
        MCPBoundSessionRegistry.shared.invalidate(sessionID: "SID-1")
        #expect(MCPBoundSessionRegistry.shared.current(for: "k1") == nil)
        #expect(MCPBoundSessionRegistry.shared.current(for: "k2") == nil)
    }

    @Test
    func teardownDuringOpenRefusesBindingAndClosesOrphanedSession() async throws {
        let gate = CoordinatorOpenGate()
        let closes = CoordinatorCloseRecorder()
        let coordinator = MCPAutoSessionCoordinator()
        let openedID = UUID().uuidString

        let openTask = Task<Result<MCPAutoSessionBinding, Error>, Never> {
            do {
                let binding = try await coordinator.ensureBound(
                    transportKey: "teardown-race",
                    attribution: MCPProjectAttribution(project: "wax", source: .explicit),
                    context: MCPConnectionContext(transportKey: "teardown-race"),
                    perform: { request in
                        switch request.command {
                        case "session_open":
                            await gate.markEntered()
                            await gate.waitForRelease()
                            return AgentBrokerResponse.success(
                                payload: .object(["session_id": .string(openedID)])
                            )
                        case "session_close":
                            if let id = request.arguments["session_id"]?.stringValue {
                                await closes.record(id)
                            }
                            return AgentBrokerResponse.success(payload: .object([:]))
                        default:
                            return AgentBrokerResponse.success(payload: .object([:]))
                        }
                    }
                )
                return .success(binding)
            } catch {
                return .failure(error)
            }
        }

        await gate.waitForEnter()
        await coordinator.markClosed()
        await gate.release()

        let result = await openTask.value
        switch result {
        case .success:
            Issue.record("ensureBound must not bind after markClosed")
        case .failure(let error):
            #expect(String(describing: error).contains("transport closed"))
        }
        #expect(await closes.closedSessionIDs == [openedID])
        #expect(await coordinator.currentBinding() == nil)
    }

    @Test
    func failedOpenIsRetryableAndRecoversOnNextCall() async throws {
        let attempts = CoordinatorAttemptCounter()
        let coordinator = MCPAutoSessionCoordinator()
        let sessionID = UUID().uuidString

        let perform: @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse = { _ in
            let attempt = await attempts.increment()
            if attempt == 1 {
                return AgentBrokerResponse(
                    outcome: .failure(payload: nil, message: "boom"),
                    shouldExit: false
                )
            }
            return AgentBrokerResponse.success(
                payload: .object(["session_id": .string(sessionID)])
            )
        }

        do {
            _ = try await coordinator.ensureBound(
                transportKey: "fail-retry",
                attribution: MCPProjectAttribution(project: "wax", source: .explicit),
                context: MCPConnectionContext(transportKey: "fail-retry"),
                perform: perform
            )
            Issue.record("first open must fail")
        } catch let error as MCPAutoSessionError {
            guard case .openFailed(let message, let retryable) = error else {
                Issue.record("expected openFailed, got \(error)")
                return
            }
            #expect(message == "boom")
            #expect(retryable)
        }

        let binding = try await coordinator.ensureBound(
            transportKey: "fail-retry",
            attribution: MCPProjectAttribution(project: "wax", source: .explicit),
            context: MCPConnectionContext(transportKey: "fail-retry"),
            perform: perform
        )
        #expect(binding.sessionID == sessionID)
        #expect(await attempts.count == 2)
        #expect(await coordinator.currentBinding()?.sessionID == sessionID)
    }

    @Test
    func leaseWindowIsDocumentedForCrashFallback() {
        #expect(VirtualSessionStore.defaultSessionLeaseSeconds == 300)
        #expect(MemoryRetentionSettings.default.recentlyClosedMs == 604_800_000)
    }
}

private actor CoordinatorOpenGate {
    private var isEntered = false
    private var isReleased = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        isEntered = true
        let pending = enteredContinuations
        enteredContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForEnter() async {
        if isEntered { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func release() {
        isReleased = true
        let pending = releaseContinuations
        releaseContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }
}

private actor CoordinatorCloseRecorder {
    private(set) var closedSessionIDs: [String] = []

    func record(_ sessionID: String) {
        closedSessionIDs.append(sessionID)
    }
}

private actor CoordinatorAttemptCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

private func withAutoSessionBroker(
    _ body: (AgentBrokerService) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-auto-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let broker = try await AgentBrokerService(
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        try await body(broker)
        try await broker.close()
    } catch {
        try? await broker.close()
        throw error
    }
}

private func makeAutoSessionRepo(named name: String) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}

private func requireAutoJSON(_ result: CallTool.Result) throws -> [String: Any] {
    let text = result.content.compactMap { block -> String? in
        if case .text(let text, _, _) = block { return text }
        return nil
    }.joined(separator: "\n")
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
#endif
