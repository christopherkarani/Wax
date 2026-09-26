#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

@Test
func rootsMapperAcceptsFileURIs() {
    #expect(MCPRootsMapper.path(fromURI: "file:///tmp/wax-proj") == "/tmp/wax-proj")
    #expect(MCPRootsMapper.path(fromURI: "file://localhost/tmp/wax-proj") == "/tmp/wax-proj")
    #expect(MCPRootsMapper.path(fromURI: "file:///tmp/my%20proj") == "/tmp/my proj")
    #expect(
        MCPRootsMapper.paths(fromURIs: ["file:///a", "  file:///b  "]) == ["/a", "/b"]
    )
}

@Test
func rootsMapperDropsNonFileURIs() {
    #expect(MCPRootsMapper.path(fromURI: "https://example.com/x") == nil)
    #expect(MCPRootsMapper.path(fromURI: "/tmp/not-a-uri") == nil)
    #expect(MCPRootsMapper.path(fromURI: "") == nil)
    #expect(MCPRootsMapper.path(fromURI: "   ") == nil)
    #expect(MCPRootsMapper.path(fromURI: "file://") == nil)
    #expect(MCPRootsMapper.paths(fromURIs: ["https://example.com/x", "file:///kept"]) == ["/kept"])
}

@Test
func rootsFetcherWithoutConnectionReturnsEmpty() async {
    let server = Server(name: "roots-test", version: "0")
    let roots = await MCPRootsFetcher.fetchRoots(server: server)
    #expect(roots == [])
}

@Test
func rootsFetcherRoundTripsLiveClientRoots() async throws {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let client = Client(
        name: "roots-live",
        version: "0",
        capabilities: Client.Capabilities(roots: Client.Capabilities.Roots())
    )
    await client.withRootsHandler { [Root(uri: "file:///tmp/live-root", name: "live")] }
    let server = Server(name: "roots-live-server", version: "0")
    try await server.start(transport: serverTransport)
    try await client.connect(transport: clientTransport)
    let roots = await MCPRootsFetcher.fetchRoots(server: server)
    #expect(roots == ["/tmp/live-root"])
    await client.disconnect()
    await server.stop()
}

@Test(.serialized)
func rootsProviderRegistryRoundTrip() async {
    MCPRootsProviderRegistry.shared.resetForTests()
    defer { MCPRootsProviderRegistry.shared.resetForTests() }
    #expect(MCPRootsProviderRegistry.shared.current(key: "roots-rt") == nil)
    MCPRootsProviderRegistry.shared.remember(key: "roots-rt") { ["/tmp"] }
    let provider = MCPRootsProviderRegistry.shared.current(key: "roots-rt")
    #expect(await provider?() == ["/tmp"])
    MCPRootsProviderRegistry.shared.remove(key: "roots-rt")
    #expect(MCPRootsProviderRegistry.shared.current(key: "roots-rt") == nil)
}

@Test(.serialized)
func rootsProviderResolvesAttributionWithoutExplicitCWD() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    MCPRootsProviderRegistry.shared.resetForTests()
    defer {
        MCPBoundSessionRegistry.shared.resetForTests()
        MCPRootsProviderRegistry.shared.resetForTests()
    }

    try await withRootsBroker { broker in
        let repo = try makeRootsGitRepo(named: "roots-resolve")
        defer { try? FileManager.default.removeItem(at: repo) }
        let calls = RootsCallCounter()
        MCPRootsProviderRegistry.shared.remember(key: "roots-resolve") {
            await calls.increment()
            return [repo.path]
        }
        let hint = MCPClientSessionHint(
            connectionKey: "roots-resolve",
            context: MCPConnectionContext(transportKey: "roots-resolve")
        )
        let first = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("lesson via client roots"),
                    "memory_type": .string("lesson"),
                ]
            ),
            broker: broker,
            sessionHint: hint
        )
        #expect(first.isError != true)
        let payload = try requireRootsJSON(first)
        #expect(payload["committed"] as? Bool == true)
        #expect(hint.current() != nil)
        #expect(hint.connectionContext()?.mcpRoots == [repo.path])

        let second = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("second lesson on the bound session"),
                    "memory_type": .string("lesson"),
                ]
            ),
            broker: broker,
            sessionHint: hint
        )
        #expect(second.isError != true)
        #expect(await calls.count == 1)
    }
}

@Test(.serialized)
func emptyRootsProviderPreservesProjectUnresolved() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    MCPRootsProviderRegistry.shared.resetForTests()
    defer {
        MCPBoundSessionRegistry.shared.resetForTests()
        MCPRootsProviderRegistry.shared.resetForTests()
    }

    try await withRootsBroker { broker in
        MCPRootsProviderRegistry.shared.remember(key: "roots-empty") { [] }
        let hint = MCPClientSessionHint(
            connectionKey: "roots-empty",
            context: MCPConnectionContext(transportKey: "roots-empty")
        )
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": .string("anything")]
            ),
            broker: broker,
            sessionHint: hint
        )
        #expect(result.isError == true)
        let payload = try requireRootsJSON(result)
        #expect(payload["code"] as? String == "project_unresolved")
        #expect(hint.current() == nil)
    }
}

private final class RootsCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func withRootsBroker(
    _ body: (AgentBrokerService) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-roots-\(UUID().uuidString)", isDirectory: true)
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

private func makeRootsGitRepo(named name: String) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}

private func requireRootsJSON(_ result: CallTool.Result) throws -> [String: Any] {
    let text = result.content.compactMap { block -> String? in
        if case .text(let text, _, _) = block { return text }
        return nil
    }.joined(separator: "\n")
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
#endif
