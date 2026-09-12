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
    #expect(!MCPProjectAttributionResolver.isProjectGatedRecall(scope: "global"))
    #expect(MCPProjectAttributionResolver.isProjectGatedRecall(scope: nil))
    #expect(MCPProjectAttributionResolver.isProjectGatedRecall(scope: "project"))
    #expect(!MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: "user_preference", scope: "global"))
    #expect(!MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: "lesson", scope: " global "))
    #expect(!MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: "lesson", scope: "GLOBAL"))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: "lesson", scope: nil))
    #expect(MCPProjectAttributionResolver.isProjectScopedWrite(memoryType: "fact", scope: nil))
}

@Test
func autoSessionKillSwitchReadsEnvironment() {
    #expect(MCPAutoSessionPolicy.isEnabled([:]))
    #expect(MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "1"]))
    #expect(!MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "0"]))
    #expect(!MCPAutoSessionPolicy.isEnabled(["WAX_MCP_AUTO_SESSION": "false"]))
}
