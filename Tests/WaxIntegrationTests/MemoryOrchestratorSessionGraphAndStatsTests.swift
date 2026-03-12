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

@Test
func legacyAccessStatsMarkerFrameIsSupersededAfterBootstrap() async throws {
    let url = temporaryStoreURL(prefix: "wax-access-stats-legacy-bootstrap")
    defer { try? FileManager.default.removeItem(at: url) }

    var baseConfig = OrchestratorConfig.default
    baseConfig.enableVectorSearch = false
    baseConfig.enableAccessStatsScoring = false

    let bootstrapSource = try await MemoryOrchestrator(at: url, config: baseConfig)
    try await bootstrapSource.remember("ACCESS_STATS_LEGACY_BOOTSTRAP_TOKEN")
    try await bootstrapSource.flush()
    try await bootstrapSource.close()

    let wax = try await Wax.open(at: url)
    let documentID = try #require(
        await wax.frameMetas().first(where: { $0.role == .document })?.id
    )

    let legacyPayload = try JSONEncoder().encode([
        FrameAccessStats(frameId: documentID, nowMs: 1_700_000_000_000)
    ])
    let legacyFrameID = try await wax.put(
        legacyPayload,
        options: FrameMetaSubset(
            role: .system,
            metadata: Metadata(["wax.internal.kind": "access_stats"])
        )
    )
    try await wax.commit()
    try await wax.close()

    var accessStatsConfig = OrchestratorConfig.default
    accessStatsConfig.enableVectorSearch = false
    accessStatsConfig.enableAccessStatsScoring = true

    let reopened = try await MemoryOrchestrator(at: url, config: accessStatsConfig)
    _ = try await reopened.recall(query: "ACCESS_STATS_LEGACY_BOOTSTRAP_TOKEN")
    try await reopened.flush()
    try await reopened.close()

    let verifiedWax = try await Wax.open(at: url)
    let metas = await verifiedWax.frameMetas()
    let accessStatsFrames = metas.filter { meta in
        meta.role == .system &&
        (meta.kind == "wax.internal.access_stats" ||
            meta.metadata?.entries["wax.internal.kind"] == "access_stats")
    }
    let liveFrames = accessStatsFrames.filter { $0.status == .active && $0.supersededBy == nil }
    let legacyFrame = try #require(accessStatsFrames.first(where: { $0.id == legacyFrameID }))

    #expect(liveFrames.count == 1)
    #expect(legacyFrame.supersededBy != nil)

    try await verifiedWax.close()
}

private func temporaryStoreURL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .appendingPathExtension("wax")
}
