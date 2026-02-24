import Foundation
import Testing
import Wax

@Suite("WaxCLI Memory Commands")
struct WaxCLIMemoryTests {

    // MARK: - Test helper

    private func withCLIMemory(
        _ body: @Sendable (MemoryOrchestrator) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-tests-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.chunking = .tokenCount(targetTokens: 16, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 120,
            expansionMaxTokens: 60,
            snippetMaxTokens: 30,
            maxSnippets: 8,
            searchTopK: 20,
            searchMode: .textOnly
        )

        let memory = try await MemoryOrchestrator(at: url, config: config)
        var deferredError: Error?
        do {
            try await body(memory)
        } catch {
            deferredError = error
        }
        do {
            try await memory.close()
        } catch {
            if deferredError == nil { deferredError = error }
        }
        if let deferredError { throw deferredError }
    }

    // MARK: - Tests

    @Test func rememberFlushRecallRoundTrip() async throws {
        try await withCLIMemory { memory in
            try await memory.remember(
                "Swift actors isolate mutable state for concurrency safety.",
                metadata: ["source": "cli-test"]
            )
            try await memory.flush()

            let context = try await memory.recall(query: "actors", frameFilter: nil)
            #expect(context.items.count > 0, "recall should return at least one item after remember + flush")
            #expect(context.items.contains { $0.text.contains("actors") },
                    "recall items should contain the remembered content")
        }
    }

    @Test func searchReturnsHits() async throws {
        try await withCLIMemory { memory in
            try await memory.remember(
                "The Wax storage engine uses WAL for durability.",
                metadata: ["source": "cli-test"]
            )
            try await memory.flush()

            let hits = try await memory.search(query: "WAL durability", mode: .text, topK: 10, frameFilter: nil)
            #expect(hits.count > 0, "search should return at least one hit")
            #expect(hits[0].score > 0, "search hit score should be greater than zero")
        }
    }

    @Test func statsReportsFrameCount() async throws {
        try await withCLIMemory { memory in
            try await memory.remember(
                "Frame count test content for CLI integration.",
                metadata: ["source": "cli-test"]
            )
            try await memory.flush()

            let stats = await memory.runtimeStats()
            #expect(stats.frameCount > 0, "frameCount should be greater than zero after remember + flush")
        }
    }

    @Test func handoffRoundTrip() async throws {
        try await withCLIMemory { memory in
            let _ = try await memory.rememberHandoff(
                content: "Carry over refactor checkpoints from session A.",
                project: "wax-cli",
                pendingTasks: ["add graph tests", "measure ranking drift"],
                sessionId: nil
            )
            try await memory.flush()

            let latest = try await memory.latestHandoff(project: "wax-cli")
            #expect(latest != nil, "latestHandoff should return a record after rememberHandoff + flush")
            #expect(latest?.content.contains("Carry over refactor checkpoints") == true)
            #expect(latest?.pendingTasks.count == 2)
            #expect(latest?.pendingTasks.contains("add graph tests") == true)
            #expect(latest?.pendingTasks.contains("measure ranking drift") == true)
            #expect(latest?.project == "wax-cli")
        }
    }

    @Test func entityUpsertAndResolveRoundTrip() async throws {
        try await withCLIMemory { memory in
            let entityID = try await memory.upsertEntity(
                key: EntityKey("agent:codex"),
                kind: "agent",
                aliases: ["codex", "assistant"],
                commit: true
            )
            #expect(entityID.rawValue > 0, "upsertEntity should return a positive entity ID")

            let matches = try await memory.resolveEntities(matchingAlias: "codex", limit: 10)
            #expect(matches.count > 0, "resolveEntities should find at least one match for the alias")
            #expect(matches[0].key.rawValue == "agent:codex")
            #expect(matches[0].kind == "agent")
        }
    }

    @Test func factAssertQueryRetractRoundTrip() async throws {
        try await withCLIMemory { memory in
            // Ensure entity exists for the fact subject
            let _ = try await memory.upsertEntity(
                key: EntityKey("agent:codex"),
                kind: "agent",
                aliases: ["codex"],
                commit: true
            )

            // Assert a fact
            let factID = try await memory.assertFact(
                subject: EntityKey("agent:codex"),
                predicate: PredicateKey("learned"),
                object: .string("patches"),
                validFromMs: nil,
                validToMs: nil,
                commit: true
            )
            #expect(factID.rawValue > 0, "assertFact should return a positive fact ID")

            // Query facts -- should find the asserted fact
            let result = try await memory.facts(
                about: EntityKey("agent:codex"),
                predicate: nil,
                asOfMs: Int64.max,
                limit: 20
            )
            #expect(result.hits.count > 0, "facts query should return at least one hit")
            #expect(result.hits[0].factId == factID)
            #expect(result.hits[0].fact.subject == EntityKey("agent:codex"))
            #expect(result.hits[0].fact.predicate == PredicateKey("learned"))
            #expect(result.hits[0].fact.object == .string("patches"))

            // Retract the fact
            try await memory.retractFact(factId: factID, atMs: nil, commit: true)

            // Query again -- should be empty now
            let afterRetract = try await memory.facts(
                about: EntityKey("agent:codex"),
                predicate: nil,
                asOfMs: Int64.max,
                limit: 20
            )
            #expect(afterRetract.hits.isEmpty, "facts query should be empty after retraction")
        }
    }
}
