#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

@Test
func rememberAndRecallSchemasAdvertiseCWD() throws {
    let rememberCWD = try #require(
        ToolSchemas.waxRemember.objectValue?["properties"]?.objectValue?["cwd"]
    )
    #expect(rememberCWD.objectValue?["type"] == .string("string"))

    let recallCWD = try #require(
        ToolSchemas.waxRecall.objectValue?["properties"]?.objectValue?["cwd"]
    )
    #expect(recallCWD.objectValue?["type"] == .string("string"))
    #expect(AgentBrokerCommandSurface.entry(for: "remember")?.acceptedArgumentKeys.contains("cwd") == true)
    #expect(AgentBrokerCommandSurface.entry(for: "recall")?.acceptedArgumentKeys.contains("cwd") == true)
}

@Test(.serialized)
func projectScopedRememberWithoutAttributionReturnsProjectUnresolvedAndBindsNothing() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }

    try await withAttributionBroker { broker in
        let hint = MCPClientSessionHint(
            connectionKey: "attr-unresolved",
            context: MCPConnectionContext(transportKey: "attr-unresolved")
        )
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("lesson without a project"),
                    "memory_type": .string("lesson"),
                ]
            ),
            broker: broker,
            sessionHint: hint
        )
        #expect(result.isError == true)
        let payload = try requireAttributionJSON(result)
        #expect(payload["code"] as? String == "project_unresolved")
        #expect(payload["committed"] as? Bool == false)
        #expect(hint.current() == nil)
        #expect(MCPBoundSessionRegistry.shared.current(for: "attr-unresolved") == nil)
    }
}

@Test(.serialized)
func syntheticRecoveryIdentityIsNeverUsedAsHostIdentity() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }

    try await withAttributionBroker { broker in
        let repo = try makeAttributionGitRepo(named: "recover-id")
        defer { try? FileManager.default.removeItem(at: repo) }
        let hint = MCPClientSessionHint(
            connectionKey: "attr-recover",
            context: MCPConnectionContext(
                transportKey: "attr-recover",
                advertisedCWD: repo.path,
                clientIdentity: MCPClientIdentity(
                    name: MCPClientIdentity.syntheticRecoveryName,
                    version: "0.0.0"
                ),
                trustedHostConversation: HostConversationKey(
                    hostNamespace: "cursor",
                    conversationID: "should-not-apply"
                )
            )
        )
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("recovery identity must stay transport-owned"),
                    "memory_type": .string("lesson"),
                    "cwd": .string(repo.path),
                ]
            ),
            broker: broker,
            sessionHint: hint
        )
        #expect(result.isError != true)
        let payload = try requireAttributionJSON(result)
        #expect(payload["committed"] as? Bool == true)
        #expect(hint.current() != nil)
        #expect(hint.currentOwnership() == .transport)
    }
}

@Test(.serialized)
func projectScopedWriteIsRecalledByNewConnectionInSameRepoOnly() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }

    try await withAttributionBroker { broker in
        let sameRepo = try makeAttributionGitRepo(named: "ac002b-same")
        let otherRepo = try makeAttributionGitRepo(named: "ac002b-other")
        defer {
            try? FileManager.default.removeItem(at: sameRepo)
            try? FileManager.default.removeItem(at: otherRepo)
        }
        let marker = "AC002B-CROSS-CONN-\(UUID().uuidString)"
        let writer = MCPClientSessionHint(
            connectionKey: "ac002b-a",
            context: MCPConnectionContext(transportKey: "ac002b-a", advertisedCWD: sameRepo.path)
        )
        let sameReader = MCPClientSessionHint(
            connectionKey: "ac002b-b",
            context: MCPConnectionContext(transportKey: "ac002b-b", advertisedCWD: sameRepo.path)
        )
        let otherReader = MCPClientSessionHint(
            connectionKey: "ac002b-c",
            context: MCPConnectionContext(transportKey: "ac002b-c", advertisedCWD: otherRepo.path)
        )

        let wrote = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string(marker),
                    "memory_type": .string("lesson"),
                    "cwd": .string(sameRepo.path),
                ]
            ),
            broker: broker,
            sessionHint: writer
        )
        #expect(wrote.isError != true)
        #expect((try requireAttributionJSON(wrote)["committed"] as? Bool) == true)

        let sameRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": .string(marker),
                    "cwd": .string(sameRepo.path),
                ]
            ),
            broker: broker,
            sessionHint: sameReader
        )
        #expect(sameRecall.isError != true)
        let sameTexts = recallResultTexts(try requireAttributionJSON(sameRecall))
        #expect(sameTexts.contains { $0.contains(marker) })

        let otherRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": .string(marker),
                    "cwd": .string(otherRepo.path),
                ]
            ),
            broker: broker,
            sessionHint: otherReader
        )
        #expect(otherRecall.isError != true)
        let otherTexts = recallResultTexts(try requireAttributionJSON(otherRecall))
        #expect(!otherTexts.contains { $0.contains(marker) })
        #expect(writer.current() != sameReader.current())
    }
}

@Test(.serialized)
func advertisedCWDDoesNotUseServerProcessCWD() async throws {
    MCPBoundSessionRegistry.shared.resetForTests()
    defer { MCPBoundSessionRegistry.shared.resetForTests() }

    try await withAttributionBroker { broker in
        let hint = MCPClientSessionHint(
            connectionKey: "attr-process-cwd",
            context: MCPConnectionContext(transportKey: "attr-process-cwd")
        )
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("must not inherit server cwd"),
                    "memory_type": .string("decision"),
                ]
            ),
            broker: broker,
            sessionHint: hint
        )
        #expect(result.isError == true)
        let payload = try requireAttributionJSON(result)
        #expect(payload["code"] as? String == "project_unresolved")
        #expect(hint.current() == nil)
    }
}

private func withAttributionBroker(
    _ body: (AgentBrokerService) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-attr-\(UUID().uuidString)", isDirectory: true)
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

private func makeAttributionGitRepo(named name: String) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}

private func recallResultTexts(_ payload: [String: Any]) -> [String] {
    let results = payload["results"] as? [[String: Any]] ?? []
    return results.compactMap { $0["text"] as? String }
}

private func requireAttributionJSON(_ result: CallTool.Result) throws -> [String: Any] {
    let text = result.content.compactMap { block -> String? in
        if case .text(let text, _, _) = block { return text }
        return nil
    }.joined(separator: "\n")
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
#endif
