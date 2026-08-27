import Foundation
import Testing
@testable import Wax

private struct UniqueTokenRankingEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "UniqueTokenRanking",
        model: "Deterministic",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let lower = text.lowercased()
        if lower.contains("qx7m-ishi-qa") {
            return [1, 0, 0, 0]
        }
        if lower.contains("ishi") {
            return [0, 1, 0, 0]
        }
        return [0, 0, 1, 0]
    }
}

private func withUniqueTokenBroker<T>(
    _ body: (AgentBrokerService) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-unique-token-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.enableTextSearch = true
    config.rag.searchMode = .hybrid(alpha: 0.5)

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: UniqueTokenRankingEmbedder(),
        orchestratorConfig: config
    )
    do {
        let result = try await body(service)
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

private func firstHitText(_ payload: [String: AgentBrokerValue]) -> String {
    let first = payload["results"]?.arrayValue?.first?.objectValue
    return first?["text"]?.stringValue
        ?? first?["preview"]?.stringValue
        ?? ""
}

private func seedUniqueTokenCorpus(
    _ service: AgentBrokerService
) async throws -> UUID {
    let started = await service.handle(.init(
        command: "session_start",
        arguments: [
            "agent_id": .string("unique-token-agent"),
            "run_id": .string("unique-token-run"),
            "project": .string("ishi-qa"),
            "repo": .string("ishi-qa"),
        ]
    ))
    #expect(started.ok == true, "session_start failed: \(started.error ?? "nil")")
    let sessionIDString = try #require(try requireObject(started.payload)["session_id"]?.stringValue)
    let sessionID = try #require(UUID(uuidString: sessionIDString))

    let nonce = await service.handle(.init(
        command: "remember",
        arguments: [
            "content": .string("WAX_MCP_QA marker Unique token qx7m-ishi-qa."),
            "session_id": .string(sessionIDString),
            "memory_type": .string("note"),
            "durability": .string("working"),
        ]
    ))
    #expect(nonce.ok == true, "nonce remember failed: \(nonce.error ?? "nil")")

    let distractors = [
        "Ishi is reviewing the family memory store tonight.",
        "Ask Ishi before changing the MCP daemon wrapper.",
        "Ishi prefers copy-store hygiene over live vacuum.",
        "Task state: wait for Ishi to confirm the ranking gold set.",
        "Ishi noted that hyphenated identifiers should stay tokens.",
    ]
    for (index, text) in distractors.enumerated() {
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(text),
                "memory_type": .string("task_state"),
                "durability": .string("durable"),
                "project": .string("ishi-qa"),
                "repo": .string("ishi-qa"),
            ]
        ))
        #expect(write.ok == true, "distractor \(index) remember failed: \(write.error ?? "nil")")
    }
    return sessionID
}

private func expectUniqueTokenHitAt1(
    _ response: AgentBrokerResponse,
    command: String
) throws {
    #expect(response.ok == true, "\(command) failed: \(response.error ?? "nil")")
    let payload = try requireObject(response.payload)
    let top = firstHitText(payload)
    #expect(
        top.localizedCaseInsensitiveContains("qx7m-ishi-qa"),
        "\(command) hit@1 missed unique token; top=\(top) display=\(payload["display_text"]?.stringValue ?? "")"
    )
}

@Test
func uniqueTokenRanksHitAt1OnSearchRecallMemoryAndCorpus() async throws {
    try await withUniqueTokenBroker { service in
        let sessionID = try await seedUniqueTokenCorpus(service)
        let query = "qx7m-ishi-qa"

        let textSearch = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "topK": .int(8),
                "session_id": .string(sessionID.uuidString),
            ]
        ))
        try expectUniqueTokenHitAt1(textSearch, command: "search text")

        let hybridSearch = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(query),
                "mode": .string("hybrid"),
                "topK": .int(8),
                "session_id": .string(sessionID.uuidString),
            ]
        ))
        try expectUniqueTokenHitAt1(hybridSearch, command: "search hybrid")

        let recall = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "scope": .string("project"),
                "project": .string("ishi-qa"),
                "repo": .string("ishi-qa"),
                "session_id": .string(sessionID.uuidString),
                "limit": .int(8),
            ]
        ))
        try expectUniqueTokenHitAt1(recall, command: "recall")

        let memorySearch = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "session_id": .string(sessionID.uuidString),
                "include_working": .bool(true),
                "include_durable": .bool(true),
                "include_episodic": .bool(false),
                "topK": .int(8),
            ]
        ))
        try expectUniqueTokenHitAt1(memorySearch, command: "memory_search")

        let corpusSearch = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "topK": .int(8),
                "rebuild": .bool(true),
            ]
        ))
        try expectUniqueTokenHitAt1(corpusSearch, command: "corpus_search")
    }
}
