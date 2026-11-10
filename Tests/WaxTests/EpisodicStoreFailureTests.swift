import Foundation
import Testing
@testable import Wax

/// One ended-session store that cannot be opened (corrupt, or locked past the
/// wait) must cost only its own hits: `compact_context` and episodic
/// `memory_search` still return the working, durable and other episodic hits.
@Suite("Episodic store failures")
struct EpisodicStoreFailureTests {
    @Test
    func compactContextSkipsAnEndedStoreThatFailsToOpen() async throws {
        try await withEpisodicFailureStores(sessionCount: 2) { stores, ended, token in
            let result = try await CompactAssembly.assemble(
                request: .init(
                    query: token, sessionID: nil, mode: .textOnly,
                    tokenBudget: 10_000, maxItems: 8, scope: .global
                ),
                stores: stores,
                tokenizer: .character
            )
            #expect(result.long.contains { $0.text.contains("durable \(token)") })
            #expect(result.medium.contains { $0.text.contains("episodic \(token)") })
            #expect(ended.openedCount == 2)
        }
    }

    @Test
    func memorySearchSkipsAnEndedStoreThatFailsToOpen() async throws {
        try await withEpisodicFailureStores(sessionCount: 2) { stores, _, token in
            let hits = try await LayeredRecall.search(
                request: LayeredRecall.SearchRequest(
                    query: token,
                    mode: .textOnly,
                    topK: 5,
                    identity: try MemorySearchIdentity.unscoped([.episodic, .durable])
                ),
                stores: stores
            )
            // Search previews highlight the matched token, so match the lane only.
            #expect(hits.contains { $0.horizon == .durable })
            #expect(hits.contains { $0.text.contains("episodic \(token)") && $0.horizon == .episodic })
        }
    }

    /// `memory_search` opens at most six ended stores per call; compact must
    /// not open every unreclaimed ended store on every call.
    @Test
    func compactContextOpensNoMoreEndedStoresThanMemorySearch() async throws {
        try await withEpisodicFailureStores(sessionCount: 9) { stores, ended, token in
            _ = try await CompactAssembly.assemble(
                request: .init(
                    query: token, sessionID: nil, mode: .textOnly,
                    tokenBudget: 10_000, maxItems: 8, scope: .global
                ),
                stores: stores,
                tokenizer: .character
            )
            #expect(ended.openedCount == 6)
        }
    }
}

/// Serves one episodic hit per manifest and throws for the first manifest, as
/// a corrupt or locked ended store does when it is opened.
private final class FailingEndedSessionStore: EndedSessionStore, @unchecked Sendable {
    let manifests: [BrokerSessionManifest]
    let token: String
    private let lock = NSLock()
    private var opened = 0

    init(manifests: [BrokerSessionManifest], token: String) {
        self.manifests = manifests
        self.token = token
    }

    var openedCount: Int {
        lock.withLock { opened }
    }

    func listManifests() throws -> [BrokerSessionManifest] {
        manifests
    }

    func search(_ query: EndedSessionSearchQuery) async throws -> [LayeredRecall.EpisodicLaneHit] {
        try open(query.manifest)
        return [
            LayeredRecall.EpisodicLaneHit(
                frameID: 7,
                score: 0.9,
                previewText: "episodic \(token) note",
                metadata: [:],
                explanations: [],
                canonicalFrameID: 7
            ),
        ]
    }

    func recall(_ query: EndedSessionRecallQuery) async throws -> [LayeredRecall.Hit] {
        try open(query.manifest)
        return [
            LayeredRecall.Hit(
                id: .episodic(sessionID: query.manifest.sessionID, frameID: 7),
                score: 0.9,
                text: "episodic \(token) note",
                preview: "episodic \(token) note",
                metadata: [:],
                explanations: [],
                timestampMs: 0
            ),
        ]
    }

    func document(_ query: EndedSessionDocumentQuery) async throws -> EndedSessionDocument {
        throw BrokerValidationError.invalid("No memory document found for frame_id \(query.frameID)")
    }

    private func open(_ manifest: BrokerSessionManifest) throws {
        lock.withLock { opened += 1 }
        if manifest.sessionID == manifests.first?.sessionID {
            throw FailingStoreError()
        }
    }
}

private struct FailingStoreError: Error {}

private func withEpisodicFailureStores(
    sessionCount: Int,
    _ body: (LayeredRecall.Stores, FailingEndedSessionStore, String) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-episodic-failure-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    config.enableAccessStatsScoring = false
    config.rag.searchMode = .textOnly
    config.defaultScopeContext = MemoryScopeContext()
    let durable = try await MemoryOrchestrator(at: url, config: config)
    do {
        let token = "WAXEPISODICFAIL\(UUID().uuidString.prefix(8))"
        try await durable.remember(
            "durable \(token) fact",
            metadata: [MemoryMetadataKeys.type: "fact"]
        )
        try await durable.flush()
        let manifests = (0..<sessionCount).map { index in
            BrokerSessionManifest(
                sessionID: UUID(),
                agentID: "ended-agent",
                runID: "ended-run-\(index)",
                project: nil,
                repo: nil,
                storePath: "/tmp/ended-session-not-on-disk-\(index).wax",
                eventLogPath: "/tmp/ended-session-not-on-disk-\(index).events",
                status: .ended,
                brokerLeaseOwnerID: nil,
                leaseExpiresAtMs: nil,
                createdAtMs: 0,
                updatedAtMs: Int64(sessionCount - index),
                endedAtMs: 0
            )
        }
        let ended = FailingEndedSessionStore(manifests: manifests, token: token)
        let stores = LayeredRecall.Stores(
            longTermMemory: durable,
            workingLane: { _ in nil },
            inferWriteScope: { _, _ in LayeredRecall.Identity() },
            preview: { $0 ?? "" },
            canonicalFrameID: { frameID, _ in frameID },
            endedSessions: ended,
            nowMs: { 0 }
        )
        try await body(stores, ended, token)
        try await durable.close()
    } catch {
        try? await durable.close()
        throw error
    }
}
