#if MCPServer
import Foundation
import Testing
@testable import Wax

private func withAgentDXBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-dx-session-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, sessionRootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

private func requireString(_ object: [String: AgentBrokerValue], _ key: String) throws -> String {
    try #require(object[key]?.stringValue)
}

private func openSession(
    _ service: AgentBrokerService,
    project: String,
    agentID: String,
    runID: String?,
    recallQuery: String? = nil,
    conversationID: String? = nil
) async throws -> [String: AgentBrokerValue] {
    var arguments: [String: AgentBrokerValue] = [
        "project": .string(project),
        "agent_id": .string(agentID),
    ]
    if let runID {
        arguments["run_id"] = .string(runID)
    }
    if let recallQuery {
        arguments["recall_query"] = .string(recallQuery)
    }
    if let conversationID {
        arguments["conversation_id"] = .string(conversationID)
    }
    let opened = await service.handle(.init(command: "session_open", arguments: arguments))
    #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
    return try requireObject(opened.payload)
}

@Test
func sessionOpenRebindsUniqueLiveAgentProjectAndSharesSessionID() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-rebind-\(UUID().uuidString.prefix(8))"
        let agentID = "dx-rebind-agent"
        let first = try await openSession(
            service,
            project: project,
            agentID: agentID,
            runID: "run-one"
        )
        let sessionID = try requireString(first, "session_id")
        #expect(first["rebound"]?.boolValue == false)
        let firstPrompt = try requireString(first, "share_prompt")
        #expect(firstPrompt.contains(sessionID))
        #expect(firstPrompt.localizedCaseInsensitiveContains("subagents gain") == false)
        #expect(firstPrompt.localizedCaseInsensitiveContains("children get wax") == false)
        #expect(firstPrompt.localizedCaseInsensitiveContains("do not get"))

        let second = try await openSession(
            service,
            project: project,
            agentID: agentID,
            runID: "run-two"
        )
        #expect(try requireString(second, "session_id") == sessionID)
        #expect(second["rebound"]?.boolValue == true)
        let sharePrompt = try requireString(second, "share_prompt")
        #expect(sharePrompt.contains(sessionID))
        #expect(sharePrompt.localizedCaseInsensitiveContains("subagents gain") == false)
        #expect(sharePrompt.localizedCaseInsensitiveContains("do not get"))

        let sameRun = try await openSession(
            service,
            project: project,
            agentID: agentID,
            runID: "run-two"
        )
        #expect(try requireString(sameRun, "session_id") == sessionID)
        #expect(sameRun["rebound"]?.boolValue == false)
    }
}

@Test
func sessionOpenOmitsUnrelatedHandoffBodyAsLowRelevance() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-handoff-\(UUID().uuidString.prefix(8))"
        let foreignProject = "dx-foreign-\(UUID().uuidString.prefix(8))"
        let homeHandoff = "WAX-HOME-HANDOFF keep harvest mapping for this coding project only."
        let foreignHandoff = "FOREIGN-HANDOFF-NEEDLE belongs to a completely different project."
        let query = "banana smoothie recipe mango pineapple blender"

        #expect(MemorySemantics.similarity(lhs: query, rhs: homeHandoff) < 0.15)

        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(homeHandoff),
                "project": .string(project),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(foreignHandoff),
                "project": .string(foreignProject),
            ]
        ))).ok == true)

        let withoutQuery = try await openSession(
            service,
            project: project,
            agentID: "dx-handoff-agent",
            runID: "handoff-run-one"
        )
        let compact = try requireObject(withoutQuery["handoff"])
        #expect(compact["found"]?.boolValue == true)
        #expect(try requireString(compact, "content").contains("WAX-HOME-HANDOFF"))
        #expect(compact["relevance"]?.stringValue != "low")

        let unrelated = try await openSession(
            service,
            project: project,
            agentID: "dx-handoff-agent",
            runID: "handoff-run-two",
            recallQuery: query
        )
        let handoff = try requireObject(unrelated["handoff"])
        #expect(handoff["found"]?.boolValue == true)
        #expect(handoff["relevance"]?.stringValue == "low")
        let content = handoff["content"]?.stringValue ?? ""
        #expect(content.isEmpty)
        #expect(content.contains("FOREIGN-HANDOFF-NEEDLE") == false)
        #expect(content.contains("WAX-HOME-HANDOFF") == false)
        let pending = handoff["pending_tasks"]?.arrayValue ?? []
        #expect(pending.isEmpty)
    }
}

@Test
func sessionOpenResumesUniqueConversationIDWhenAgentProjectDoesNotMatch() async throws {
    try await withAgentDXBroker { service, sessionRoot in
        let project = "dx-conv-\(UUID().uuidString.prefix(8))"
        let conversationID = "conv-\(UUID().uuidString)"
        let first = try await openSession(
            service,
            project: project,
            agentID: "dx-conv-agent-a",
            runID: "conv-run-a",
            conversationID: conversationID
        )
        let sessionID = try requireString(first, "session_id")
        let uuid = try #require(UUID(uuidString: sessionID))
        let stamped = try BrokerSessionPersistence.loadManifest(rootURL: sessionRoot, sessionID: uuid)
        #expect(stamped.conversationID == conversationID)

        let resumed = try await openSession(
            service,
            project: project,
            agentID: "dx-conv-agent-b",
            runID: "conv-run-b",
            conversationID: conversationID
        )
        #expect(try requireString(resumed, "session_id") == sessionID)
        #expect(resumed["rebound"]?.boolValue == false)
    }
}

@Test
func sessionClosePayloadListsPromotedAndLeftoverReasons() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-close-\(UUID().uuidString.prefix(8))"
        let needle = "WAXDXPROMO-\(UUID().uuidString.prefix(8))"
        let opened = try await openSession(
            service,
            project: project,
            agentID: "dx-close-agent",
            runID: "close-run"
        )
        let sessionID = try requireString(opened, "session_id")

        let decision = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: keep \(needle) as the close-harvest gold token."),
                "memory_type": .string("decision"),
                "session_id": .string(sessionID),
                "project": .string(project),
            ]
        ))
        #expect(decision.ok == true, "decision remember failed: \(decision.error ?? "nil")")

        let note = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working scratch note with no recalls about ranking noise."),
                "memory_type": .string("note"),
                "durability": .string("working"),
                "session_id": .string(sessionID),
                "project": .string(project),
            ]
        ))
        #expect(note.ok == true, "note remember failed: \(note.error ?? "nil")")

        let closed = await service.handle(.init(
            command: "session_close",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string("Closed after promoting the gold token."),
                "project": .string(project),
            ]
        ))
        #expect(closed.ok == true, "session_close failed: \(closed.error ?? "nil")")
        let payload = try requireObject(closed.payload)
        #expect(payload["promoted_count"]?.intValue == 1)
        let promoted = try #require(payload["promoted"]?.arrayValue)
        #expect(promoted.isEmpty == false)
        let first = try #require(promoted.first?.objectValue)
        let memoryID = try requireString(first, "memory_id")
        #expect(memoryID.hasPrefix("durable:"))
        #expect(first["type"]?.stringValue == "decision")
        #expect((first["preview"]?.stringValue ?? "").contains(needle))
        #expect((payload["leftover_count"]?.intValue ?? 0) >= 1)
        let reasons = payload["leftover_reasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(reasons.contains("note_low_recall"))
    }
}
#endif
