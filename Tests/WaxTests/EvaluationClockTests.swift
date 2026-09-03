import Foundation
import Testing
@testable import Wax
import WaxCore

private let evaluationClockNowMs: Int64 = 1_700_000_000_000
private let evaluationClockHourMs: Int64 = 60 * 60 * 1000
private let evaluationClockDayMs: Int64 = 24 * evaluationClockHourMs

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
    func upsertEntityInvokesInjectedNow() async throws {
        let clock = RecordingNowMs(value: evaluationClockNowMs)
        try await withOrchestrator(
            structuredMemory: true,
            nowMsProvider: { clock.now() }
        ) { orchestrator in
            let before = clock.calls
            let key = EntityKey("person:evaluation-clock")
            _ = try await orchestrator.upsertEntity(
                key: key,
                kind: "person",
                aliases: ["Evaluation Clock"]
            )
            #expect(clock.calls > before)
            let match = try #require(try await orchestrator.entity(forKey: key))
            #expect(match.key == key)
            #expect(match.kind == "person")
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
    func fastRAGBuildUsesDeterministicNowMsNotWallClock() async throws {
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
    func fastRAGBuildUsesDeterministicNowMsNotZeroSentinel() async throws {
        let agedNowMs = evaluationClockNowMs + 20 * evaluationClockDayMs
        try await withOrchestrator(
            structuredMemory: false,
            deterministicNowMs: agedNowMs
        ) { orchestrator in
            _ = try await orchestrator.rememberHandoff(
                content: "Waxfile ranking-clock pin for recency explanations."
            )
            let recall = try await orchestrator.recall(query: "Waxfile ranking-clock")
            let item = try #require(recall.items.first)
            #expect(item.explanations.contains("stale handoff"))
            #expect(item.explanations.contains("recent handoff") == false)
        }
    }

    @Test
    func fastRAGAccessRerankAndPackUseInjectedNowMs() async throws {
        try await withOrchestrator(
            structuredMemory: false,
            enableAccessStatsScoring: true
        ) { orchestrator in
            let frameId = try await orchestrator.rememberHandoff(
                content: "Waxfile access-clock pin for recently used explanations."
            )
            await orchestrator.seedAccessStats(
                frameId: frameId,
                from: FrameAccessStats(
                    frameId: frameId,
                    nowMs: evaluationClockNowMs - evaluationClockHourMs
                )
            )
            let recall = try await orchestrator.recall(query: "Waxfile access-clock")
            let item = try #require(recall.items.first { $0.frameId == frameId })
            #expect(item.explanations.contains("recently used"))
        }

        let staleAccessNowMs = evaluationClockNowMs + 48 * evaluationClockHourMs
        try await withOrchestrator(
            structuredMemory: false,
            enableAccessStatsScoring: true,
            deterministicNowMs: staleAccessNowMs
        ) { orchestrator in
            let frameId = try await orchestrator.rememberHandoff(
                content: "Waxfile access-clock pin for recently used explanations."
            )
            await orchestrator.seedAccessStats(
                frameId: frameId,
                from: FrameAccessStats(
                    frameId: frameId,
                    nowMs: evaluationClockNowMs - evaluationClockHourMs
                )
            )
            let recall = try await orchestrator.recall(query: "Waxfile access-clock")
            let item = try #require(recall.items.first { $0.frameId == frameId })
            #expect(item.explanations.contains("recently used") == false)
        }
    }

    @Test
    func fastRAGNilDeterministicNowMsDoesNotUseWallClock() async throws {
        try await withOrchestrator(structuredMemory: false) { orchestrator in
            _ = try await orchestrator.rememberHandoff(
                content: "Waxfile ranking-clock pin for recency explanations."
            )
            let config = FastRAGConfig(searchMode: .textOnly)
            #expect(config.deterministicNowMs == nil)
            let context = try await FastRAGContextBuilder().build(
                query: "Waxfile ranking-clock",
                wax: orchestrator.wax,
                session: orchestrator.session,
                config: config
            )
            let item = try #require(context.items.first)
            // Wall clock (~2026) would mark a 2023 handoff stale. SearchRequest.nowMs
            // is non-optional, so the nil-clock path passes 0, which looks recent.
            #expect(item.explanations.contains("recent handoff"))
            #expect(item.explanations.contains("stale handoff") == false)
        }
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

        let unexpired = [
            MemoryMetadataKeys.type: MemoryType.handoff.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.ephemeral.rawValue,
            MemoryMetadataKeys.createdAtMs: String(createdAtMs),
        ]
        let aged = MemorySemantics.rankingReasons(
            metadata: unexpired,
            scope: nil,
            nowMs: createdAtMs + 20 * evaluationClockDayMs
        )
        #expect(aged.reasons.contains("stale handoff"))
        #expect(aged.reasons.contains("recent handoff") == false)
    }
}

private final class RecordingNowMs: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let value: Int64

    init(value: Int64) {
        self.value = value
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func now() -> Int64 {
        lock.lock()
        _calls += 1
        lock.unlock()
        return value
    }
}

private func withOrchestrator(
    structuredMemory: Bool,
    enableAccessStatsScoring: Bool = false,
    deterministicNowMs: Int64 = evaluationClockNowMs,
    nowMsProvider: (@Sendable () -> Int64)? = nil,
    _ body: (MemoryOrchestrator) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-eval-clock-" + UUID().uuidString)
        .appendingPathExtension("wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = structuredMemory
    config.enableAccessStatsScoring = enableAccessStatsScoring
    config.rag.searchMode = .textOnly
    config.rag.deterministicNowMs = deterministicNowMs
    let provider = nowMsProvider ?? { evaluationClockNowMs }

    let orchestrator = try await MemoryOrchestrator(
        at: url,
        config: config,
        nowMsProvider: provider
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
