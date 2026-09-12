#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

@Suite
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
            let text = try requireAutoJSON(recalled).description
            #expect(!text.contains(marker) || a.current() != b.current())
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
                        conversationID: "chat-a",
                        repoIdentity: "host-ids"
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
                        conversationID: "chat-b",
                        repoIdentity: "host-ids"
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
    func leaseWindowIsDocumentedForCrashFallback() {
        #expect(VirtualSessionStore.defaultSessionLeaseSeconds == 300)
        #expect(MemoryRetentionSettings.default.recentlyClosedMs == 604_800_000)
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
