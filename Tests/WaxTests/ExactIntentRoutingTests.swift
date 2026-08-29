import Foundation
import Testing
@testable import Wax

private struct ExactIntentTestEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "ExactIntentTests",
        model: "Deterministic",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let lower = text.lowercased()
        if lower.contains("agentbroker") {
            return [1, 0, 0, 0]
        }
        return [0, 1, 0, 0]
    }
}

private func withExactIntentMemory<T>(
    _ body: (MemoryOrchestrator) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-exact-intent-" + UUID().uuidString)
        .appendingPathExtension("wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = true
    config.enableStructuredMemory = false
    config.rag.searchMode = .hybrid(alpha: 0.5)

    let memory = try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: ExactIntentTestEmbedder()
    )
    do {
        let result = try await body(memory)
        try await memory.close()
        try? FileManager.default.removeItem(at: url)
        return result
    } catch {
        try? await memory.close()
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

private func withTextOnlyBroker<T>(
    _ body: (AgentBrokerService) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-exact-intent-broker-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try await AgentBrokerService(
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: {
            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            config.enableTextSearch = true
            config.rag.searchMode = .hybrid(alpha: 0.5)
            return config
        }()
    )
    do {
        let result = try await body(service)
        try await service.close()
        try? FileManager.default.removeItem(at: root)
        return result
    } catch {
        try? await service.close()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

@Test
func exactIntentClassifierCoversIdentifiersAndQuotedNamesWithoutBareWordPromotion() {
    let identifiers = [
        "550E8400-E29B-41D4-A716-446655440000",
        "build.agent_v2",
        "arch/f1fd967c/T2",
        "#PR-145",
        "AgentBrokerClient",
        "HYBRID_DEFAULT_QUERY_MARKER",
    ]
    for query in identifiers {
        #expect(RuleBasedQueryClassifier.isExactIntentQuery(query))
    }

    #expect(RuleBasedQueryClassifier.isExactIntentQuery(#""Ada Lovelace""#))
    #expect(RuleBasedQueryClassifier.isExactIntentQuery("'Ada Lovelace'"))
    #expect(!RuleBasedQueryClassifier.isExactIntentQuery("Swift"))
    #expect(!RuleBasedQueryClassifier.isExactIntentQuery("Noah Lovelace"))
    #expect(!RuleBasedQueryClassifier.isExactIntentQuery("tell me about AgentBrokerClient"))
}

@Test
func omittedRecallRoutesExactIntentToTextAndExplicitHybridRemainsHybrid() async throws {
    try await withExactIntentMemory { memory in
        try await memory.remember("Canonical AgentBrokerClient identifier.")
        try await memory.flush()

        let implicit = try await memory.recallExecution(query: "AgentBrokerClient", topK: 5)
        #expect(implicit.requestedMode == .textOnly)
        #expect(implicit.effectiveMode == .textOnly)
        #expect(implicit.queryEmbeddingState == .notRequested)

        let quoted = try await memory.recallExecution(query: #""Ada Lovelace""#, topK: 5)
        #expect(quoted.requestedMode == .textOnly)
        #expect(quoted.effectiveMode == .textOnly)
        #expect(quoted.queryEmbeddingState == .notRequested)

        let generic = try await memory.recallExecution(query: "actors", topK: 5)
        #expect(generic.requestedMode == .hybrid(alpha: 0.5))
        #expect(generic.effectiveMode == .hybrid(alpha: 0.5))
        #expect(generic.queryEmbeddingState == .available)

        let explicit = try await memory.recallExecution(
            query: "AgentBrokerClient",
            mode: .hybrid(alpha: 0.25),
            topK: 5
        )
        #expect(explicit.requestedMode == .hybrid(alpha: 0.25))
        #expect(explicit.effectiveMode == .hybrid(alpha: 0.25))
        #expect(explicit.queryEmbeddingState == .available)

        let explicitVector = try await memory.recallExecution(
            query: "AgentBrokerClient",
            mode: .vectorOnly,
            topK: 5
        )
        #expect(explicitVector.requestedMode == .vectorOnly)
        #expect(explicitVector.effectiveMode == .vectorOnly)
        #expect(explicitVector.queryEmbeddingState == .available)
    }
}

@Test
func exactTokenMatchBeatsPrefixAndSupportsCaseInsensitiveNames() async throws {
    try await withExactIntentMemory { memory in
        let prefix = try await memory.remember(
            "The AgentBroker-Client prefix distractor is not canonical."
        )
        let exact = try await memory.remember(
            "The AgentBroker record is the canonical client name."
        )
        try await memory.flush()

        let results = try await memory.searchExecution(
            query: "aGeNtBrOkEr",
            mode: .textOnly,
            topK: 5
        )
        #expect(results.hits.first?.frameId == exact.frameId)
        #expect(results.hits.first?.frameId != prefix.frameId)
        #expect(results.hits.first?.explanations.contains("exact identifier match") == true)
    }
}

@Test
func quotedMultiTokenNameBeatsHyphenatedPrefix() async throws {
    try await withExactIntentMemory { memory in
        let prefix = try await memory.remember(
            "Ada Lovelace-Foundation notes are a related but different name."
        )
        let exact = try await memory.remember(
            "The canonical profile is Ada Lovelace, mathematician and author."
        )
        try await memory.flush()

        let results = try await memory.searchExecution(
            query: #""Ada Lovelace""#,
            mode: .textOnly,
            topK: 5
        )
        #expect(results.hits.first?.frameId == exact.frameId)
        #expect(results.hits.first?.frameId != prefix.frameId)
    }
}

@Test
func exactIdentifiersWithUuidDotsUnderscoresAndPunctuationBeatPrefixes() async throws {
    try await withExactIntentMemory { memory in
        let cases = [
            "550E8400-E29B-41D4-A716-446655440000",
            "build.agent_v2",
            "arch/f1fd967c/T2",
            "#PR-145",
        ]
        for identifier in cases {
            let prefix = try await memory.remember("Prefix " + identifier + "-extra distractor.")
            let exact = try await memory.remember("Canonical identifier " + identifier + ". record.")
            try await memory.flush()

            let results = try await memory.searchExecution(
                query: identifier,
                mode: .textOnly,
                topK: 8
            )
            #expect(results.hits.first?.frameId == exact.frameId)
            #expect(results.hits.first?.frameId != prefix.frameId)
        }
    }
}

@Test
func sessionOpenRecallUsesSafeImplicitExactRoutingAndMergedRanking() async throws {
    try await withTextOnlyBroker { service in
        let exact = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Canonical AgentBroker name from durable memory."),
                "metadata": .object([
                    MemoryMetadataKeys.project: .string("exact-intent"),
                    MemoryMetadataKeys.repo: .string("exact-intent"),
                ]),
            ]
        ))
        #expect(exact.ok == true)

        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("exact-intent-agent"),
                "run_id": .string("exact-intent-run"),
                "project": .string("exact-intent"),
                "repo": .string("exact-intent"),
            ]
        ))
        #expect(started.ok == true)
        let startedPayload = try requireObject(started.payload)
        let sessionID = try #require(startedPayload["session_id"]?.stringValue)

        let prefix = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("AgentBroker-Client prefix from the current session."),
                "session_id": .string(sessionID),
                "memory_type": .string("note"),
                "durability": .string("working"),
            ]
        ))
        #expect(prefix.ok == true)

        let merged = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("AgentBroker"),
                "scope": .string("global"),
                "session_id": .string(sessionID),
                "limit": .int(8),
            ]
        ))
        #expect(merged.ok == true)
        let mergedPayload = try requireObject(merged.payload)
        #expect(mergedPayload["requested_mode"]?.stringValue == "text")
        #expect(mergedPayload["effective_mode"]?.stringValue == "text")
        let mergedResults = mergedPayload["results"]?.arrayValue ?? []
        let mergedFirstText = mergedResults.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(mergedFirstText.localizedCaseInsensitiveContains("canonical AgentBroker"))

        let opened = await service.handle(.init(
            command: "session_open",
            arguments: [
                "project": .string("exact-intent"),
                "repo": .string("exact-intent"),
                "agent_id": .string("exact-intent-reopen"),
                "run_id": .string("exact-intent-reopen"),
                "recall_query": .string("AgentBroker"),
            ]
        ))
        #expect(opened.ok == true)
        let openPayload = try requireObject(opened.payload)
        let recall = try requireObject(openPayload["recall"])
        #expect(recall["requested_mode"]?.stringValue == "text")
        #expect(recall["effective_mode"]?.stringValue == "text")
    }
}
