import Foundation
import Testing
@testable import Wax

@Test
func hostConversationKeysNamespaceEqualRawIDs() {
    let claude = HostConversationKey(
        hostNamespace: "claude",
        conversationID: "chat-1"
    )
    let cursor = HostConversationKey(
        hostNamespace: "cursor",
        conversationID: "chat-1"
    )
    #expect(claude.wireConversationID == "claude:chat-1")
    #expect(cursor.wireConversationID == "cursor:chat-1")
    #expect(claude != cursor)
    #expect(claude.wireConversationID != cursor.wireConversationID)
}

@Test
func transportKeyHashesConnectionAndNeverEqualsRawKey() {
    let key = MCPTransportKey(rawConnectionKey: "mcp-session-abc")
    #expect(key.hashedConversationID.hasPrefix("transport:"))
    #expect(!key.hashedConversationID.contains("mcp-session-abc"))
    #expect(key.hashedConversationID.count == "transport:".count + 64)
    let other = MCPTransportKey(rawConnectionKey: "mcp-session-xyz")
    #expect(key.hashedConversationID != other.hashedConversationID)
}

@Test
func transportKeyIsDeterministicAndDoesNotInventBrokerUUID() {
    let first = MCPTransportKey(rawConnectionKey: "stdio")
    let second = MCPTransportKey(rawConnectionKey: "stdio")
    #expect(first.hashedConversationID == second.hashedConversationID)
    #expect(UUID(uuidString: first.hashedConversationID) == nil)
}

@Test
func syntheticRecoveryIdentityCannotOwnHostConversation() {
    let recovered = MCPClientIdentity(name: MCPClientIdentity.syntheticRecoveryName, version: "0.0.0")
    #expect(recovered.isSyntheticRecovery)
    #expect(!recovered.canOwnHostConversation)

    let cursor = MCPClientIdentity(name: "cursor", version: "1.0")
    #expect(!cursor.isSyntheticRecovery)
    #expect(cursor.canOwnHostConversation)
}

@Test
func initializeParserMarksSyntheticRecoveryClient() {
    let body = Data(
        #"{"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"wax-mcp-session-recover","version":"0.0.0"}}}"#
            .utf8
    )
    let identity = MCPInitializeIdentityParser.parse(from: body)
    #expect(identity.isSyntheticRecovery)
    #expect(!identity.canOwnHostConversation)
}

@Test
func projectAttributionPrefersExplicitThenCWDThenSingleRoot() throws {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("attr-explicit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: repo) }

    let explicit = MCPProjectAttributionResolver.resolve(
        explicitProject: "Wax",
        explicitRepo: "Wax",
        advertisedCWD: repo.path,
        mcpRoots: [repo.path]
    )
    #expect(explicit.source == .explicit)
    #expect(explicit.project == "Wax")
    #expect(explicit.isResolved)

    let cwd = MCPProjectAttributionResolver.resolve(
        explicitProject: nil,
        explicitRepo: nil,
        advertisedCWD: repo.path,
        mcpRoots: []
    )
    #expect(cwd.source == .advertisedCWD)
    #expect(cwd.isResolved)
    #expect(cwd.project == repo.lastPathComponent)

    let root = MCPProjectAttributionResolver.resolve(
        explicitProject: nil,
        explicitRepo: nil,
        advertisedCWD: nil,
        mcpRoots: [repo.path]
    )
    #expect(root.source == .mcpRoot)
    #expect(root.isResolved)

    let unresolved = MCPProjectAttributionResolver.resolve(
        explicitProject: nil,
        explicitRepo: nil,
        advertisedCWD: nil,
        mcpRoots: []
    )
    #expect(unresolved.source == .unresolved)
    #expect(!unresolved.isResolved)
}

@Test
func projectAttributionDoesNotUseProcessCWDAndRejectsAmbiguousRoots() {
    let unresolved = MCPProjectAttributionResolver.resolve(
        explicitProject: nil,
        explicitRepo: nil,
        advertisedCWD: nil,
        mcpRoots: ["/tmp/a", "/tmp/b"],
        processDirectoryPath: FileManager.default.currentDirectoryPath
    )
    #expect(unresolved.source == .unresolved)
    #expect(!unresolved.isResolved)
}

@Test
func globalPersonRecallIsNotProjectGated() {
    #expect(!MCPProjectAttributionResolver.isProjectGatedRecall(scope: .global))
    #expect(!MCPProjectAttributionResolver.isProjectGatedRecall(scope: .session))
    #expect(MCPProjectAttributionResolver.isProjectGatedRecall(scope: .project))

    #expect(!MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .userPreference, scope: nil))
    #expect(!MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .userPreference, scope: .durable))
    #expect(!MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .userPreference, scope: .session))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .lesson, scope: nil))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .lesson, scope: .session))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .lesson, scope: .durable))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: .fact, scope: nil))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: nil, scope: nil))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: nil, scope: .durable))

    for type in MemoryType.allCases {
        #expect(
            MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: type, scope: nil)
                == (type != .userPreference)
        )
    }
}

@Test
func autoSessionKillSwitchReadsEnvironment() {
    #expect(MCPAutoSessionPolicy.isEnabled([:]))
    #expect(MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "1"]))
    #expect(!MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "0"]))
    #expect(!MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "false"]))
}

@Test
func rootsMapperAcceptsFileURIsAndBarePaths() {
    #expect(MCPRootsMapper.path(fromURI: "file:///tmp/wax-proj") == "/tmp/wax-proj")
    #expect(MCPRootsMapper.path(fromURI: "file://localhost/tmp/wax-proj") == "/tmp/wax-proj")
    #expect(MCPRootsMapper.path(fromURI: "file:///tmp/my%20proj") == "/tmp/my proj")
    #expect(MCPRootsMapper.path(fromURI: "/tmp/bare-path") == "/tmp/bare-path")
    #expect(
        MCPRootsMapper.paths(fromURIs: ["file:///a", "  file:///b  "]) == ["/a", "/b"]
    )
}

@Test
func rootsMapperDropsNonFileURIs() {
    #expect(MCPRootsMapper.path(fromURI: "https://example.com/x") == nil)
    #expect(MCPRootsMapper.path(fromURI: "not-a-path") == nil)
    #expect(MCPRootsMapper.path(fromURI: "") == nil)
    #expect(MCPRootsMapper.path(fromURI: "   ") == nil)
    #expect(MCPRootsMapper.path(fromURI: "file://") == nil)
    #expect(MCPRootsMapper.paths(fromURIs: ["https://example.com/x", "file:///kept"]) == ["/kept"])
}

@Test
func initializeRootsParserCapturesEmbeddedRoots() {
    let body = Data(
        #"{"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"cursor","version":"1.0"},"roots":[{"uri":"file:///tmp/alpha"},{"uri":"file:///tmp/beta","name":"b"}],"capabilities":{"roots":{"listChanged":true}}}}"#
            .utf8
    )
    #expect(MCPInitializeRootsParser.parseRoots(from: body) == ["/tmp/alpha", "/tmp/beta"])

    let metaBody = Data(
        #"{"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"x","version":"0"},"_meta":{"roots":["file:///tmp/meta-root"]}}}"#
            .utf8
    )
    #expect(MCPInitializeRootsParser.parseRoots(from: metaBody) == ["/tmp/meta-root"])

    let bareBody = Data(
        #"{"jsonrpc":"2.0","method":"initialize","params":{"roots":["/tmp/bare"]}}"#.utf8
    )
    #expect(MCPInitializeRootsParser.parseRoots(from: bareBody) == ["/tmp/bare"])

    let emptyBody = Data(
        #"{"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"x","version":"0"},"capabilities":{}}}"#
            .utf8
    )
    #expect(MCPInitializeRootsParser.parseRoots(from: emptyBody) == [])
}

@Test
func stickyAttributionPersistsLastResolvedPerTransportKey() {
    MCPStickyAttributionRegistry.shared.resetForTests()
    defer { MCPStickyAttributionRegistry.shared.resetForTests() }
    #expect(MCPStickyAttributionRegistry.shared.current(for: "sticky-a") == nil)

    let unresolved = MCPProjectAttribution(source: .unresolved)
    MCPStickyAttributionRegistry.shared.remember(transportKey: "sticky-a", attribution: unresolved)
    #expect(MCPStickyAttributionRegistry.shared.current(for: "sticky-a") == nil)

    let resolved = MCPProjectAttribution(project: "Wax", repo: "Wax", cwdPath: "/tmp/wax", source: .advertisedCWD)
    MCPStickyAttributionRegistry.shared.remember(transportKey: "sticky-a", attribution: resolved)
    #expect(MCPStickyAttributionRegistry.shared.current(for: "sticky-a") == resolved)
    #expect(MCPStickyAttributionRegistry.shared.current(for: "sticky-b") == nil)

    MCPStickyAttributionRegistry.shared.remove(for: "sticky-a")
    #expect(MCPStickyAttributionRegistry.shared.current(for: "sticky-a") == nil)
}
