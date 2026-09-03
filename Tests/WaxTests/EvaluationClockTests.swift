import Foundation
import Testing
@testable import Wax
import WaxCore

private let evaluationClockNowMs: Int64 = 1_700_000_000_000
private let evaluationClockDayMs: Int64 = 24 * 60 * 60 * 1000

struct EvaluationClockTests {

    @Test
    func handoffCreatedAtMsUsesInjectedNow() async throws {
        try await withOrchestrator(structuredMemory: false) { orchestrator in
            let frameId = try await orchestrator.rememberHandoff(
                content: "Evaluation-clock handoff for waxfile ranking."
            )
            let hits = try await orchestrator.search(
                query: "Evaluation-clock handoff",
                mode: .textOnly,
                topK: 5
            )
            let hit = try #require(hits.first { $0.frameId == frameId })
            #expect(hit.metadata[MemoryMetadataKeys.createdAtMs] == String(evaluationClockNowMs))
        }
    }

    @Test
    func upsertEntityUsesInjectedNow() async throws {
        try await withOrchestrator(structuredMemory: true) { orchestrator in
            let key = EntityKey("person:evaluation-clock")
            _ = try await orchestrator.upsertEntity(
                key: key,
                kind: "person",
                aliases: ["Evaluation Clock"]
            )
            let match = try #require(try await orchestrator.entity(forKey: key))
            #expect(match.key == key)
            #expect(match.kind == "person")

            let source = try orchestratorSource()
            let upsertBody = try #require(functionBody(named: "upsertEntity", in: source))
            #expect(upsertBody.contains("nowProvider()"))
            #expect(upsertBody.contains("Date()") == false)
        }
    }

    @Test
    func assertFactSystemTimeUsesInjectedNow() async throws {
        try await withOrchestrator(structuredMemory: true) { orchestrator in
            let subject = EntityKey("service:evaluation-clock")
            _ = try await orchestrator.assertFact(
                subject: subject,
                predicate: PredicateKey("status"),
                object: .string("active")
            )
            let facts = try await orchestrator.facts(about: subject, limit: 10)
            let hit = try #require(facts.hits.first)
            #expect(hit.system.fromMs == evaluationClockNowMs)
            #expect(hit.valid.fromMs == evaluationClockNowMs)
        }
    }

    @Test
    func assertFactMonotonicBumpWhenProviderRepeats() async throws {
        try await withOrchestrator(structuredMemory: true) { orchestrator in
            let subject = EntityKey("service:evaluation-clock-mono")
            _ = try await orchestrator.assertFact(
                subject: subject,
                predicate: PredicateKey("status"),
                object: .string("active")
            )
            _ = try await orchestrator.assertFact(
                subject: subject,
                predicate: PredicateKey("region"),
                object: .string("us-west")
            )
            let facts = try await orchestrator.facts(about: subject, limit: 10)
            let times = facts.hits.map(\.system.fromMs).sorted()
            #expect(times == [evaluationClockNowMs, evaluationClockNowMs + 1])
        }
    }

    @Test
    func fastRAGBuildUsesSingleDeterministicNowMs() async throws {
        try await withOrchestrator(structuredMemory: false) { orchestrator in
            _ = try await orchestrator.rememberHandoff(
                content: "Waxfile ranking-clock pin for recency explanations."
            )
            let recall = try await orchestrator.recall(query: "Waxfile ranking-clock")
            let item = try #require(recall.items.first)
            #expect(item.explanations.contains("recent handoff"))
            #expect(item.explanations.contains("stale handoff") == false)
        }
    }

    @Test
    func fastRAGContextBuilderSourceHasNoDateAndOneNowMs() throws {
        let source = try fastRAGSource()
        #expect(source.contains("Date()") == false)
        #expect(source.contains("let nowMs = clamped.deterministicNowMs"))
        #expect(source.contains("nowMs: nowMs ?? 0"))
        #expect(source.contains("nowMs: nowMs"))
        #expect(source.contains("AccessFrequencyRanker.rerank"))
        #expect(source.contains("RecallAssembly.pack"))
        #expect(source.contains("accessScoringNowMs") == false)
    }

    @Test
    func remainingOrchestratorDateIsOnlyNowMsProviderDefault() throws {
        let source = try orchestratorSource()
        let dateCallCount = source.components(separatedBy: "Date()").count - 1
        #expect(dateCallCount == 1)
        #expect(source.contains(
            "nowMsProvider: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }"
        ))
        let handoffBody = try #require(functionBody(named: "rememberHandoffSerialized", in: source))
        #expect(handoffBody.contains("nowProvider()"))
        #expect(handoffBody.contains("Date()") == false)
        let nextBody = try #require(functionBody(named: "nextStructuredSystemMs", in: source))
        #expect(nextBody.contains("nowProvider()"))
        #expect(nextBody.contains("Date()") == false)
    }

    @Test
    func zeroNowMsBoostsRecencyAndSkipsExpiry() {
        let createdAtMs = evaluationClockNowMs
        let expiresAtMs = createdAtMs + evaluationClockDayMs
        let metadata = [
            MemoryMetadataKeys.type: MemoryType.handoff.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.ephemeral.rawValue,
            MemoryMetadataKeys.createdAtMs: String(createdAtMs),
            MemoryMetadataKeys.expiresAtMs: String(expiresAtMs),
        ]
        let atZero = MemorySemantics.parse(metadata: metadata, nowMs: 0)
        #expect(atZero.isExpired == false)
        let zeroReasons = MemorySemantics.rankingReasons(
            metadata: metadata,
            scope: nil,
            nowMs: 0
        )
        #expect(zeroReasons.reasons.contains("recent handoff"))

        let expired = MemorySemantics.parse(metadata: metadata, nowMs: expiresAtMs)
        #expect(expired.isExpired)
        let atCreated = MemorySemantics.rankingReasons(
            metadata: metadata,
            scope: nil,
            nowMs: createdAtMs
        )
        #expect(atCreated.reasons.contains("recent handoff"))
    }
}

private func withOrchestrator(
    structuredMemory: Bool,
    _ body: (MemoryOrchestrator) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-eval-clock-" + UUID().uuidString)
        .appendingPathExtension("wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = structuredMemory
    config.enableAccessStatsScoring = false
    config.rag.searchMode = .textOnly
    config.rag.deterministicNowMs = evaluationClockNowMs

    let orchestrator = try await MemoryOrchestrator(
        at: url,
        config: config,
        nowMsProvider: { evaluationClockNowMs }
    )
    do {
        try await body(orchestrator)
        try await orchestrator.close()
        try? FileManager.default.removeItem(at: url)
    } catch {
        try? await orchestrator.close()
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func fastRAGSource() throws -> String {
    try String(
        contentsOf: repoRoot().appendingPathComponent("Sources/Wax/RAG/FastRAGContextBuilder.swift"),
        encoding: .utf8
    )
}

private func orchestratorSource() throws -> String {
    try String(
        contentsOf: repoRoot().appendingPathComponent("Sources/Wax/Orchestrator/MemoryOrchestrator.swift"),
        encoding: .utf8
    )
}

private func functionBody(named name: String, in source: String) -> String? {
    guard let nameRange = source.range(of: "func \(name)(") else { return nil }
    let fromName = source[nameRange.lowerBound...]
    guard let openBrace = fromName.firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = openBrace
    while index < fromName.endIndex {
        let character = fromName[index]
        if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 {
                return String(fromName[openBrace...index])
            }
        }
        index = fromName.index(after: index)
    }
    return nil
}
