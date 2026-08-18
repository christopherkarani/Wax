import Foundation
import Testing

#if MCPServer
@testable import wax_mcp
@testable import Wax

private func withIsolatedBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-session-model-\(UUID().uuidString)", isDirectory: true)
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

private func resultTexts(_ payload: [String: AgentBrokerValue]) -> [String] {
    payload["results"]?.arrayValue?.compactMap { result in
        result.objectValue?["text"]?.stringValue ?? result.objectValue?["preview"]?.stringValue
    } ?? []
}

@Test
func sessionScopedRecallMergesDurableAndSessionNotes() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("recall-agent"),
                "run_id": .string("recall-run"),
            ]
        ))
        #expect(started.ok == true)
        let sessionID = try requireString(try requireObject(started.payload), "session_id")

        let durable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("rv is a Zig CLI that evaluates policy and attaches an OS sandbox."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
            ]
        ))
        #expect(durable.ok == true)

        let sessionNote = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Session-only note: do not promote. CLEAN-TOKEN-20260818"),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(sessionNote.ok == true)

        let scoped = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("What is rv?"),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "limit": .int(10),
            ]
        ))
        #expect(scoped.ok == true, "scoped recall failed: \(scoped.error ?? "nil")")
        let payload = try requireObject(scoped.payload)
        let texts = resultTexts(payload)
        #expect(texts.contains { $0.contains("Zig CLI") && $0.contains("policy") })
        #expect(texts.contains { $0.contains("CLEAN-TOKEN-20260818") })
    }
}

@Test
func sessionStartReusesActiveSessionForSameAgentAndRun() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("same-agent"),
                "run_id": .string("same-run"),
            ]
        ))
        #expect(first.ok == true)
        let firstPayload = try requireObject(first.payload)
        let firstID = try requireString(firstPayload, "session_id")

        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("same-agent"),
                "run_id": .string("same-run"),
            ]
        ))
        #expect(second.ok == true)
        let secondPayload = try requireObject(second.payload)
        #expect(try requireString(secondPayload, "session_id") == firstID)
        #expect(secondPayload["resumed"]?.boolValue == true)
    }
}

@Test
func sessionStartInfersProjectFromClientCwdNotBrokerBinary() async throws {
    try await withIsolatedBroker { service, _ in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("cwd-agent"),
                "run_id": .string("cwd-run"),
                "cwd": .string(repo.path),
            ]
        ))
        #expect(started.ok == true)
        let payload = try requireObject(started.payload)
        #expect(payload["project"]?.stringValue == repo.lastPathComponent)
        #expect(payload["project"]?.stringValue != "Wax")
        #expect(payload["repo"]?.stringValue == repo.lastPathComponent)
    }
}

@Test
func corpusSearchIncludesDurableLongTermFrames() async throws {
    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("DCG is the destructive command guard for ryk policy evaluation."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))
        #expect(write.ok == true)

        let corpus = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string("rv DCG"),
                "mode": .string("text"),
                "topK": .int(8),
                "rebuild": .bool(false),
            ]
        ))
        #expect(corpus.ok == true, "corpus_search failed: \(corpus.error ?? "nil")")
        let payload = try requireObject(corpus.payload)
        let texts = resultTexts(payload)
        #expect(texts.contains { $0.contains("destructive command guard") })
    }
}

@Test
func memorySearchWithoutSessionIDStillSearchesDurableWhenMultipleSessionsAreActive() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(command: "session_start"))
        let second = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        #expect(second.ok == true)

        let token = "minilmdimscanary\(UUID().uuidString.prefix(8).lowercased())"
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Durable fact \(token) about MiniLM dimensions."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "include_working": .bool(true),
                "include_durable": .bool(true),
            ]
        ))
        #expect(search.ok == true, "memory_search failed: \(search.error ?? "nil")")
        let payload = try requireObject(search.payload)
        let texts = resultTexts(payload)
        let display = payload["display_text"]?.stringValue ?? ""
        #expect(
            texts.contains { $0.localizedCaseInsensitiveContains(token) } || display.localizedCaseInsensitiveContains(token),
            "expected durable hit for \(token); display=\(display) texts=\(texts)"
        )
    }
}

@Test
func sessionSynthesizeWithMultipleSessionsAsksForSessionIDNotMissingSession() async throws {
    try await withIsolatedBroker { service, _ in
        #expect((await service.handle(.init(command: "session_start"))).ok == true)
        #expect((await service.handle(.init(command: "session_start"))).ok == true)

        let synthesized = await service.handle(.init(command: "session_synthesize"))
        #expect(synthesized.ok == false)
        #expect((synthesized.error ?? "").contains("more than one session is active"))
        #expect(!(synthesized.error ?? "").contains("no active session is available"))
    }
}

@Test
func memoryPromoteDoesNotRecommendDoNotPromoteCanaryAfterOneRecall() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        let canary = "Session-only note: do not promote. CLEAN-TOKEN-20260818"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(canary),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        #expect((await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(canary),
                "session_id": .string(sessionID),
                "mode": .string("text"),
            ]
        ))).ok == true)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(promote.ok == true)
        let payload = try requireObject(promote.payload)
        let proposal = try requireObject(payload["proposal"])
        #expect(proposal["should_write"]?.boolValue == false)
    }
}

@Test
func recallRejectsEmptyQuery() async throws {
    try await withIsolatedBroker { service, _ in
        let empty = await service.handle(.init(
            command: "recall",
            arguments: ["query": .string("   ")]
        ))
        #expect(empty.ok == false)
        #expect((empty.error ?? "").contains("query"))
    }
}

@Test
func searchRejectsAlphaUnlessHybrid() async throws {
    try await withIsolatedBroker { service, _ in
        let rejected = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("alpha"),
                "mode": .string("text"),
                "alpha": .double(0.7),
            ]
        ))
        #expect(rejected.ok == false)
        #expect((rejected.error ?? "").contains("alpha"))
    }
}

@Test
func factsQueryOmitsSentinelAsOfWhenCallerDidNotPassOne() async throws {
    try await withIsolatedBroker { service, _ in
        #expect((await service.handle(.init(
            command: "fact_assert",
            arguments: [
                "subject": .string("wax"),
                "predicate": .string("status"),
                "object": .string("open"),
            ]
        ))).ok == true)

        let queried = await service.handle(.init(command: "facts_query"))
        #expect(queried.ok == true)
        let payload = try requireObject(queried.payload)
        #expect(payload["as_of"] == .null || payload["as_of"] == nil)
        if let raw = payload["as_of"]?.intValue {
            #expect(raw != Int64.max)
        }
    }
}

@Test
func compactContextIncludesLiveSessionNote() async throws {
    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try requireString(try requireObject(started.payload), "session_id")
        let token = "COMPACT-LIVE-\(UUID().uuidString.prefix(8))"

        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Working session note \(token) must appear in short context."),
                "session_id": .string(sessionID),
            ]
        ))).ok == true)

        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string("unrelated compact query"),
                "session_id": .string(sessionID),
                "mode": .string("text"),
                "token_budget": .int(800),
            ]
        ))
        #expect(compact.ok == true, "compact_context failed: \(compact.error ?? "nil")")
        let payload = try requireObject(compact.payload)
        let short = payload["short_context"]?.arrayValue ?? []
        #expect(short.contains { $0.objectValue?["preview"]?.stringValue?.contains(token) == true
            || $0.objectValue?["text"]?.stringValue?.contains(token) == true })
    }
}

#endif
