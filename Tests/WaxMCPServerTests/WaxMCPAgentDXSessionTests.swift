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
    conversationID: String? = nil,
    sessionID: String? = nil,
    repo: String? = nil
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
    if let sessionID {
        arguments["session_id"] = .string(sessionID)
    }
    if let repo {
        arguments["repo"] = .string(repo)
    }
    let opened = await service.handle(.init(command: "session_open", arguments: arguments))
    #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
    return try requireObject(opened.payload)
}

private func payloadContains(_ payload: [String: AgentBrokerValue], _ needle: String) -> Bool {
    if let results = payload["results"]?.arrayValue {
        if results.contains(where: { hit in
            let object = hit.objectValue
            return (object?["text"]?.stringValue
                ?? object?["preview"]?.stringValue
                ?? "").contains(needle)
        }) {
            return true
        }
    }
    for key in ["short_context", "medium_context", "long_context"] {
        if payload[key]?.arrayValue?.contains(where: { hit in
            let object = hit.objectValue
            return (object?["text"]?.stringValue
                ?? object?["preview"]?.stringValue
                ?? "").contains(needle)
        }) == true {
            return true
        }
    }
    return false
}

private func sessionRecall(
    _ service: AgentBrokerService,
    sessionID: String,
    query: String,
    project: String
) async throws -> [String: AgentBrokerValue] {
    let recall = await service.handle(.init(
        command: "recall",
        arguments: [
            "query": .string(query),
            "session_id": .string(sessionID),
            "scope": .string("session"),
            "mode": .string("text"),
            "project": .string(project),
            "limit": .int(8),
        ]
    ))
    #expect(recall.ok == true, "session recall failed: \(recall.error ?? "nil")")
    return try requireObject(recall.payload)
}

private func projectRecall(
    _ service: AgentBrokerService,
    query: String,
    project: String
) async throws -> [String: AgentBrokerValue] {
    let recall = await service.handle(.init(
        command: "recall",
        arguments: [
            "query": .string(query),
            "scope": .string("project"),
            "mode": .string("text"),
            "project": .string(project),
            "repo": .string(project),
            "limit": .int(8),
        ]
    ))
    #expect(recall.ok == true, "project recall failed: \(recall.error ?? "nil")")
    return try requireObject(recall.payload)
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
func sessionOpenBootstrapHandoffUsesProjectInferredFromCWD() async throws {
    try await withAgentDXBroker { service, _ in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dx-cwd-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let project = repo.lastPathComponent
        let local = "LOCAL-CWD-HANDOFF-\(UUID().uuidString)"
        let foreign = "FOREIGN-CWD-HANDOFF-\(UUID().uuidString)"
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(local),
                "project": .string(project),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(foreign),
                "project": .string("foreign-\(UUID().uuidString)"),
            ]
        ))).ok == true)

        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "cwd": .string(repo.path),
                "agent_id": .string("dx-cwd-handoff-agent"),
                "run_id": .string("dx-cwd-handoff-run"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let handoff = try requireObject(try requireObject(opened.payload)["handoff"])
        #expect((handoff["content"]?.stringValue ?? "").contains(local))
        #expect((handoff["content"]?.stringValue ?? "").contains(foreign) == false)
    }
}

@Test
func sessionOpenWithoutResolvableProjectDoesNotReadGlobalLatestHandoff() async throws {
    try await withAgentDXBroker { service, _ in
        let foreign = "FOREIGN-UNSCOPED-HANDOFF-\(UUID().uuidString)"
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(foreign),
                "project": .string("foreign-\(UUID().uuidString)"),
            ]
        ))).ok == true)

        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "agent_id": .string("unscoped-handoff-agent"),
                "run_id": .string("unscoped-handoff-run"),
            ]
        ))
        #expect(opened.ok == true)
        let handoff = try requireObject(try requireObject(opened.payload)["handoff"])
        #expect(handoff["found"]?.boolValue == false)
        #expect((handoff["content"]?.stringValue ?? "").contains(foreign) == false)
    }
}

@Test
func sessionOpenScopesHandoffAfterResolvingExistingTargetSession() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-resolved-handoff-\(UUID().uuidString.prefix(8))"
        let local = "LOCAL-RESOLVED-HANDOFF-\(UUID().uuidString)"
        let foreign = "FOREIGN-RESOLVED-HANDOFF-\(UUID().uuidString)"
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: ["content": .string(local), "project": .string(project)]
        ))).ok == true)
        let first = try await openSession(
            service,
            project: project,
            agentID: "resolved-handoff-agent",
            runID: "resolved-handoff-run"
        )
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(foreign),
                "project": .string("foreign-\(UUID().uuidString)"),
            ]
        ))).ok == true)

        let reopened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "agent_id": .string("resolved-handoff-agent"),
                "run_id": .string("resolved-handoff-run"),
            ]
        ))
        #expect(reopened.ok == true)
        let payload = try requireObject(reopened.payload)
        #expect(try requireString(payload, "session_id") == requireString(first, "session_id"))
        let handoff = try requireObject(payload["handoff"])
        #expect((handoff["content"]?.stringValue ?? "").contains(local))
        #expect((handoff["content"]?.stringValue ?? "").contains(foreign) == false)
    }
}

@Test
func sessionOpenResumesConversationIDForSameAgentAndProject() async throws {
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
            agentID: "dx-conv-agent-a",
            runID: "conv-run-b",
            conversationID: conversationID
        )
        #expect(try requireString(resumed, "session_id") == sessionID)
        #expect(resumed["rebound"]?.boolValue == true)
    }
}

@Test
func sessionOpenDoesNotResumeConversationIDAcrossAgentNamespaces() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-conv-namespace-\(UUID().uuidString.prefix(8))"
        let conversationID = "conv-namespace-\(UUID().uuidString)"
        let first = try await openSession(
            service,
            project: project,
            agentID: "host-a",
            runID: "host-a-run",
            conversationID: conversationID
        )
        let second = try await openSession(
            service,
            project: project,
            agentID: "host-b",
            runID: "host-b-run",
            conversationID: conversationID
        )
        let firstID = try requireString(first, "session_id")
        let secondID = try requireString(second, "session_id")
        #expect(firstID != secondID)

        let reopenedFirst = try await openSession(
            service,
            project: project,
            agentID: "host-a",
            runID: "host-a-run-two",
            conversationID: conversationID
        )
        let reopenedSecond = try await openSession(
            service,
            project: project,
            agentID: "host-b",
            runID: "host-b-run-two",
            conversationID: conversationID
        )
        #expect(try requireString(reopenedFirst, "session_id") == firstID)
        #expect(try requireString(reopenedSecond, "session_id") == secondID)
    }
}

@Test
func sessionOpenResumesUniqueConversationWithoutAgentID() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-conv-anonymous-\(UUID().uuidString.prefix(8))"
        let conversationID = "conv-anonymous-\(UUID().uuidString)"
        let first = await service.handle(.init(
            command: "session_open",
            arguments: [
                "project": .string(project),
                "conversation_id": .string(conversationID),
            ]
        ))
        #expect(first.ok == true)
        let firstID = try requireString(requireObject(first.payload), "session_id")

        let reopened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "project": .string(project),
                "conversation_id": .string(conversationID),
            ]
        ))
        #expect(reopened.ok == true)
        #expect(try requireString(requireObject(reopened.payload), "session_id") == firstID)
    }
}

@Test
func sessionOpenKeepsDistinctExplicitConversationIDsInDistinctSessions() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-conv-split-\(UUID().uuidString.prefix(8))"
        let first = try await openSession(
            service,
            project: project,
            agentID: "hermes-cli",
            runID: "host-run-one",
            conversationID: "hermes-conversation-one"
        )
        let second = try await openSession(
            service,
            project: project,
            agentID: "hermes-cli",
            runID: "host-run-two",
            conversationID: "hermes-conversation-two"
        )

        #expect(try requireString(first, "session_id") != requireString(second, "session_id"))
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
                "scope": .string("session"),
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
        let leftoverCount = try #require(payload["leftover_count"]?.intValue)
        #expect(leftoverCount >= 1)
        let reasons = payload["leftover_reasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(reasons.contains("note_low_recall"))
        #expect(reasons.count == leftoverCount)
    }
}

@Test
func sessionOpenDoesNotLetSessionIDHintCaptureExplicitConversation() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-hint-steal-\(UUID().uuidString.prefix(8))"
        let first = try await openSession(
            service,
            project: project,
            agentID: "hint-agent",
            runID: "hint-run-one",
            conversationID: "host-conversation-one"
        )
        let firstID = try requireString(first, "session_id")

        let second = try await openSession(
            service,
            project: project,
            agentID: "hint-agent",
            runID: "hint-run-two",
            conversationID: "host-conversation-two",
            sessionID: firstID
        )
        let secondID = try requireString(second, "session_id")
        #expect(secondID != firstID)

        let resumedFirst = try await openSession(
            service,
            project: project,
            agentID: "hint-agent",
            runID: "hint-run-one",
            conversationID: "host-conversation-one",
            sessionID: secondID
        )
        #expect(try requireString(resumedFirst, "session_id") == firstID)
    }
}

@Test
func sessionOpenKeepsWorkingMemoryIsolatedAcrossConversations() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-iso-\(UUID().uuidString.prefix(8))"
        let alphaToken = "WAXDXALPHA-\(UUID().uuidString.prefix(8))"
        let betaToken = "WAXDXBETA-\(UUID().uuidString.prefix(8))"
        let alpha = try await openSession(
            service,
            project: project,
            agentID: "iso-agent",
            runID: "alpha-run",
            conversationID: "conv-alpha"
        )
        let alphaID = try requireString(alpha, "session_id")
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working task \(alphaToken) belongs only to alpha."),
                "memory_type": .string("task_state"),
                "durability": .string("working"),
                "scope": .string("session"),
                "session_id": .string(alphaID),
                "project": .string(project),
            ]
        ))).ok == true)

        let beta = try await openSession(
            service,
            project: project,
            agentID: "iso-agent",
            runID: "beta-run",
            conversationID: "conv-beta"
        )
        let betaID = try requireString(beta, "session_id")
        #expect(betaID != alphaID)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working task \(betaToken) belongs only to beta."),
                "memory_type": .string("task_state"),
                "durability": .string("working"),
                "scope": .string("session"),
                "session_id": .string(betaID),
                "project": .string(project),
            ]
        ))).ok == true)

        let betaRecall = try await sessionRecall(
            service,
            sessionID: betaID,
            query: alphaToken,
            project: project
        )
        #expect(payloadContains(betaRecall, alphaToken) == false)

        let betaSeesOwn = try await sessionRecall(
            service,
            sessionID: betaID,
            query: betaToken,
            project: project
        )
        #expect(payloadContains(betaSeesOwn, betaToken))
        #expect(payloadContains(betaSeesOwn, alphaToken) == false)

        let switched = try await openSession(
            service,
            project: project,
            agentID: "iso-agent",
            runID: "alpha-run-two",
            conversationID: "conv-alpha"
        )
        #expect(try requireString(switched, "session_id") == alphaID)
        let alphaRecall = try await sessionRecall(
            service,
            sessionID: alphaID,
            query: alphaToken,
            project: project
        )
        #expect(payloadContains(alphaRecall, alphaToken))
        #expect(payloadContains(alphaRecall, betaToken) == false)

        let compactBeta = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(alphaToken),
                "session_id": .string(betaID),
                "mode": .string("text"),
                "max_items": .int(6),
                "token_budget": .int(512),
            ]
        ))
        #expect(compactBeta.ok == true, "compact_context failed: \(compactBeta.error ?? "nil")")
        #expect(payloadContains(try requireObject(compactBeta.payload), alphaToken) == false)
    }
}

@Test
func sessionCloseThenReopenConversationMintsNewUUIDPreservingDurableMemory() async throws {
    try await withAgentDXBroker { service, _ in
        let project = "dx-reopen-\(UUID().uuidString.prefix(8))"
        let workingToken = "WAXDXWORKING-\(UUID().uuidString.prefix(8))"
        let durableToken = "WAXDXDURABLE-\(UUID().uuidString.prefix(8))"
        let opened = try await openSession(
            service,
            project: project,
            agentID: "reopen-agent",
            runID: "reopen-run",
            conversationID: "conv-reopen"
        )
        let sessionID = try requireString(opened, "session_id")

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working scratch \(workingToken) must die with the session."),
                "memory_type": .string("task_state"),
                "durability": .string("working"),
                "scope": .string("session"),
                "session_id": .string(sessionID),
                "project": .string(project),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Lesson: \(durableToken) survives intended close and reopen."),
                "memory_type": .string("lesson"),
                "durability": .string("durable"),
                "session_id": .string(sessionID),
                "project": .string(project),
                "repo": .string(project),
            ]
        ))).ok == true)

        let closed = await service.handle(.init(
            command: "session_close",
            arguments: [
                "session_id": .string(sessionID),
                "content": .string("Closed alpha conversation."),
                "project": .string(project),
            ]
        ))
        #expect(closed.ok == true, "session_close failed: \(closed.error ?? "nil")")
        #expect(try requireObject(closed.payload)["active"]?.boolValue == false)

        let reopened = try await openSession(
            service,
            project: project,
            agentID: "reopen-agent",
            runID: "reopen-run-two",
            conversationID: "conv-reopen"
        )
        let reopenedID = try requireString(reopened, "session_id")
        #expect(reopenedID != sessionID)
        #expect(UUID(uuidString: reopenedID) != nil)

        let durableRecall = try await projectRecall(
            service,
            query: durableToken,
            project: project
        )
        #expect(payloadContains(durableRecall, durableToken))

        let workingProject = try await projectRecall(
            service,
            query: workingToken,
            project: project
        )
        #expect(payloadContains(workingProject, workingToken) == false)

        let newSessionRecall = try await sessionRecall(
            service,
            sessionID: reopenedID,
            query: workingToken,
            project: project
        )
        #expect(payloadContains(newSessionRecall, workingToken) == false)
    }
}

@Test
func compactContextWithoutResolvableProjectDoesNotWidenToForeignDurable() async throws {
    try await withAgentDXBroker { service, _ in
        let foreign = "FOREIGN-COMPACT-\(UUID().uuidString)"
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Durable lesson \(foreign) belongs to another project."),
                "memory_type": .string("lesson"),
                "durability": .string("durable"),
                "project": .string("foreign-\(UUID().uuidString)"),
            ]
        ))).ok == true)

        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "agent_id": .string("unscoped-compact-agent"),
                "run_id": .string("unscoped-compact-run"),
                "conversation_id": .string("unscoped-compact-conv"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let sessionID = try requireString(try requireObject(opened.payload), "session_id")

        let compacted = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(foreign),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "max_items": .int(8),
                "token_budget": .int(512),
            ]
        ))
        #expect(compacted.ok == true, "compact_context failed: \(compacted.error ?? "nil")")
        #expect(payloadContains(try requireObject(compacted.payload), foreign) == false)
    }
}

@Test
func nativeRememberRecallRoundTripUsesProjectInferredFromCWD() async throws {
    try await withAgentDXBroker { service, _ in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dx-cwd-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let project = repo.lastPathComponent
        let token = "zxqcwdlesson\(UUID().uuidString.prefix(8))"
        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "cwd": .string(repo.path),
                "agent_id": .string("dx-cwd-roundtrip-agent"),
                "run_id": .string("dx-cwd-roundtrip-run"),
                "conversation_id": .string("dx-cwd-roundtrip-conv"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let sessionID = try requireString(try requireObject(opened.payload), "session_id")

        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Durable lesson \(token) belongs to the cwd-inferred project."),
                "session_id": .string(sessionID),
                "memory_type": .string("lesson"),
                "durability": .string("durable"),
            ]
        ))
        #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(token),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "limit": .int(8),
            ]
        ))
        #expect(recalled.ok == true, "recall failed: \(recalled.error ?? "nil")")
        let payload = try requireObject(recalled.payload)
        #expect(payload["scope"]?.stringValue == "project")
        #expect(payload["project"]?.stringValue == project)
        #expect(payload["project_miss"]?.boolValue != true)
        #expect(payloadContains(payload, token))
    }
}

@Test
func rememberSurfacesUnresolvedProjectWhenCwdHasNoGitIdentity() async throws {
    try await withAgentDXBroker { service, _ in
        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "agent_id": .string("dx-unresolved-agent"),
                "run_id": .string("dx-unresolved-run"),
                "conversation_id": .string("dx-unresolved-conv"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let sessionID = try requireString(try requireObject(opened.payload), "session_id")
        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Lesson: unresolved project must be visible on remember."),
                "session_id": .string(sessionID),
                "memory_type": .string("lesson"),
            ]
        ))
        #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")
        let payload = try requireObject(remembered.payload)
        #expect(payload["unresolved_project"]?.boolValue == true)
        #expect(payload["project"]?.stringValue == nil)
        let next = try requireString(payload, "next_action")
        #expect(next.contains("scope=global"))
        let display = try requireString(payload, "display_text")
        #expect(display.lowercased().contains("unresolved"))
    }
}

@Test
func rememberRecallUsesClientCWDWhenLiveSessionHasNoProject() async throws {
    try await withAgentDXBroker { service, _ in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dx-cwd-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let project = repo.lastPathComponent
        let token = "zxqcwdfallback\(UUID().uuidString.prefix(8))"
        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "agent_id": .string("dx-cwd-fallback-agent"),
                "run_id": .string("dx-cwd-fallback-run"),
                "conversation_id": .string("dx-cwd-fallback-conv"),
            ]
        ))
        #expect(opened.ok == true, "session_open failed: \(opened.error ?? "nil")")
        let sessionID = try requireString(try requireObject(opened.payload), "session_id")

        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Durable lesson \(token) is stamped from remember cwd."),
                "session_id": .string(sessionID),
                "memory_type": .string("lesson"),
                "durability": .string("durable"),
                "cwd": .string(repo.path),
            ]
        ))
        #expect(remembered.ok == true, "remember failed: \(remembered.error ?? "nil")")

        let recalled = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(token),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "cwd": .string(repo.path),
                "limit": .int(8),
            ]
        ))
        #expect(recalled.ok == true, "recall failed: \(recalled.error ?? "nil")")
        let payload = try requireObject(recalled.payload)
        #expect(payload["scope"]?.stringValue == "project")
        #expect(payload["project"]?.stringValue == project)
        #expect(payload["project_miss"]?.boolValue != true)
        #expect(payloadContains(payload, token))
    }
}

@Test
func sessionOpenDoesNotResumeConversationAcrossRepos() async throws {
    try await withAgentDXBroker { service, _ in
        let conversationID = "conv-repo-\(UUID().uuidString)"
        let first = try await openSession(
            service,
            project: "dx-repo-a",
            agentID: "repo-agent",
            runID: "repo-run-a",
            conversationID: conversationID,
            repo: "repo-a"
        )
        let second = try await openSession(
            service,
            project: "dx-repo-a",
            agentID: "repo-agent",
            runID: "repo-run-b",
            conversationID: conversationID,
            repo: "repo-b"
        )
        #expect(try requireString(first, "session_id") != requireString(second, "session_id"))
    }
}
#endif
