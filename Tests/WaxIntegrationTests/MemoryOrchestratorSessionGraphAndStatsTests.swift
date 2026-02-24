import Foundation
import Testing
import Wax

@Test
func structuredMemoryBridgeRoundTripPersistsAcrossReopen() async throws {
    let url = temporaryStoreURL(prefix: "wax-structured-bridge")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = true

    let memory = try await MemoryOrchestrator(at: url, config: config)
    let subject = EntityKey("agent:codex")
    let predicate = PredicateKey("learned_behavior")

    let entityID = try await memory.upsertEntity(
        key: subject,
        kind: "agent",
        aliases: ["codex", "assistant"]
    )
    #expect(entityID.rawValue > 0)

    let factID = try await memory.assertFact(
        subject: subject,
        predicate: predicate,
        object: .string("Prefer focused patches")
    )
    #expect(factID.rawValue > 0)

    let before = try await memory.facts(about: subject, predicate: predicate, limit: 20)
    #expect(before.hits.count >= 1)
    #expect(before.hits.contains { hit in
        if case .string(let text) = hit.fact.object {
            return text == "Prefer focused patches"
        }
        return false
    })

    try await memory.close()

    let reopened = try await MemoryOrchestrator(at: url, config: config)
    let afterReopen = try await reopened.facts(about: subject, predicate: predicate, limit: 20)
    #expect(afterReopen.hits.count >= 1)

    try await reopened.retractFact(factId: factID)
    let afterRetract = try await reopened.facts(about: subject, predicate: predicate, limit: 20)
    #expect(afterRetract.hits.isEmpty)
    try await reopened.close()
}

@Test
func accessStatsPersistAsSystemFrameWhenEnabled() async throws {
    let url = temporaryStoreURL(prefix: "wax-access-stats")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableAccessStatsScoring = true

    let memory = try await MemoryOrchestrator(at: url, config: config)
    try await memory.remember("ACCESS_STATS_PERSISTENCE_TOKEN")
    try await memory.flush()

    _ = try await memory.recall(query: "ACCESS_STATS_PERSISTENCE_TOKEN")
    try await memory.flush()
    try await memory.close()

    let wax = try await Wax.open(at: url)
    let metas = await wax.frameMetas()
    let hasAccessStatsFrame = metas.contains(where: { meta in
        meta.kind == "wax.internal.access_stats" &&
        meta.role == .system &&
        meta.status == .active &&
        meta.supersededBy == nil
    })
    #expect(hasAccessStatsFrame)
    try await wax.close()

    let reopened = try await MemoryOrchestrator(at: url, config: config)
    _ = try await reopened.recall(query: "ACCESS_STATS_PERSISTENCE_TOKEN")
    try await reopened.close()
}

private func temporaryStoreURL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .appendingPathExtension("wax")
}
