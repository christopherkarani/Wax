import Foundation
import Testing
@testable import Wax

struct EndedSessionStoreTests {
    @Test
    func diskStoreListsEndedManifestAndSearchesRememberedText() async throws {
        try await withEndedSessionDisk { store, manifest, token in
            let manifests = try store.listManifests()
            #expect(manifests.map(\.sessionID) == [manifest.sessionID])

            let hits = try await store.search(
                EndedSessionSearchQuery(
                    manifest: manifest,
                    query: token,
                    mode: .textOnly,
                    topK: 5
                )
            )
            #expect(hits.contains { hit in
                (hit.previewText ?? "").contains(token) && hit.canonicalFrameID != nil
            })
        }
    }

    @Test
    func diskStoreSearchAndRecallReturnEmptyWhenStoreFileIsMissing() async throws {
        try await withEndedSessionDisk { store, manifest, token in
            try FileManager.default.removeItem(atPath: manifest.storePath)
            let searchHits = try await store.search(
                EndedSessionSearchQuery(
                    manifest: manifest,
                    query: token,
                    mode: .textOnly,
                    topK: 5
                )
            )
            #expect(searchHits.isEmpty)
            let recallHits = try await store.recall(
                EndedSessionRecallQuery(
                    manifest: manifest,
                    query: token,
                    mode: .textOnly,
                    topK: 5,
                    frameFilter: nil
                )
            )
            #expect(recallHits.isEmpty)
            await #expect(throws: BrokerValidationError.self) {
                try await store.document(
                    EndedSessionDocumentQuery(sessionID: manifest.sessionID, frameID: 1)
                )
            }
        }
    }

    @Test
    func diskStoreSkipsReclaimTombstoneWithEmptyStorePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-ended-tombstone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let nowMs: Int64 = 1
        let tombstone = BrokerSessionManifest(
            sessionID: sessionID,
            agentID: "ended-agent",
            runID: "ended-run",
            project: "Wax",
            repo: "Wax",
            storePath: "",
            eventLogPath: "",
            status: .ended,
            brokerLeaseOwnerID: nil,
            leaseExpiresAtMs: nil,
            createdAtMs: nowMs,
            updatedAtMs: nowMs,
            endedAtMs: nowMs,
            reclaimedAtMs: nowMs
        )
        try BrokerSessionPersistence.saveManifest(
            tombstone,
            to: BrokerSessionPersistence.manifestURL(rootURL: root, sessionID: sessionID)
        )
        let store = DiskEndedSessionStore(
            sessionRootURL: root,
            noEmbedder: true,
            enableAccessStatsScoring: false,
            readiness: EmbeddingReadiness()
        )
        let searchHits = try await store.search(
            EndedSessionSearchQuery(manifest: tombstone, query: "anything", mode: .textOnly, topK: 5)
        )
        #expect(searchHits.isEmpty)
        let recallHits = try await store.recall(
            EndedSessionRecallQuery(
                manifest: tombstone,
                query: "anything",
                mode: .textOnly,
                topK: 5,
                frameFilter: nil
            )
        )
        #expect(recallHits.isEmpty)
        await #expect(throws: BrokerValidationError.self) {
            try await store.document(
                EndedSessionDocumentQuery(sessionID: sessionID, frameID: 1)
            )
        }
        await #expect(throws: BrokerValidationError.self) {
            try await store.withMemory(at: URL(fileURLWithPath: "")) { _ in 0 }
        }
    }

    @Test
    func diskStoreRecallsRememberedText() async throws {
        try await withEndedSessionDisk { store, manifest, token in
            let hits = try await store.recall(
                EndedSessionRecallQuery(
                    manifest: manifest,
                    query: token,
                    mode: .textOnly,
                    topK: 5,
                    frameFilter: nil
                )
            )
            #expect(hits.contains { $0.text.contains(token) })
            #expect(hits.contains { $0.explanations.contains("recent session episode") })
            #expect(hits.contains { $0.id.horizon == .episodic })
        }
    }

    @Test
    func diskStoreLoadsDocumentByFrameID() async throws {
        try await withEndedSessionDisk { store, manifest, token in
            let hits = try await store.search(
                EndedSessionSearchQuery(
                    manifest: manifest,
                    query: token,
                    mode: .textOnly,
                    topK: 1
                )
            )
            let frameID = try #require(hits.first?.canonicalFrameID ?? hits.first?.frameID)
            let document = try await store.document(
                EndedSessionDocumentQuery(sessionID: manifest.sessionID, frameID: frameID)
            )
            #expect(document.text.contains(token))
            #expect(document.sessionID == manifest.sessionID)
            #expect(document.frameID == frameID)
        }
    }

    @Test
    func diskStoreWithMemoryClosesSoALaterSearchCanReopen() async throws {
        try await withEndedSessionDisk { store, manifest, token in
            let counted: Int = try await store.withMemory(at: URL(fileURLWithPath: manifest.storePath)) { memory in
                let docs = try await memory.corpusSourceDocuments()
                return docs.count
            }
            #expect(counted >= 1)

            let hits = try await store.search(
                EndedSessionSearchQuery(
                    manifest: manifest,
                    query: token,
                    mode: .textOnly,
                    topK: 5
                )
            )
            #expect(hits.isEmpty == false)
        }
    }

    @Test
    func inMemoryStoreServesCannedSearchAndRecallHits() async throws {
        let sessionID = UUID()
        let manifest = endedTestManifest(sessionID: sessionID, storePath: "/tmp/ended-session-missing.wax")
        let cannedSearch = LayeredRecall.EpisodicLaneHit(
            frameID: 11,
            score: 0.8,
            previewText: "canned search hit",
            metadata: [:],
            explanations: ["fixture"],
            canonicalFrameID: 11
        )
        let cannedRecall = LayeredRecall.Hit(
            id: .episodic(sessionID: sessionID, frameID: 11),
            score: 0.8,
            text: "canned recall hit",
            preview: "canned recall hit",
            metadata: [:],
            explanations: ["recent session episode"],
            timestampMs: 1
        )
        let store = InMemoryEndedSessionStore(
            manifests: [manifest],
            searchHits: [sessionID: [cannedSearch]],
            recallHits: [sessionID: [cannedRecall]],
            documents: [
                EndedSessionDocument(
                    sessionID: sessionID,
                    frameID: 11,
                    text: "canned document",
                    metadata: [:],
                    timestampMs: 1,
                    agentID: manifest.agentID,
                    runID: manifest.runID
                )
            ]
        )

        #expect(try store.listManifests().map(\.sessionID) == [sessionID])
        let searchHits = try await store.search(
            EndedSessionSearchQuery(manifest: manifest, query: "q", mode: .textOnly, topK: 3)
        )
        #expect(searchHits.map(\.frameID) == [11])
        let recallHits = try await store.recall(
            EndedSessionRecallQuery(manifest: manifest, query: "q", mode: .textOnly, topK: 3, frameFilter: nil)
        )
        #expect(recallHits.map(\.text) == ["canned recall hit"])
        let document = try await store.document(
            EndedSessionDocumentQuery(sessionID: sessionID, frameID: 11)
        )
        #expect(document.text == "canned document")
    }

    @Test
    func layeredRecallSearchUsesEndedSessionStoreForEpisodicLane() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-ended-layered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false
        let longTerm = try await MemoryOrchestrator(
            at: root.appendingPathComponent("durable.wax"),
            config: config
        )
        do {
            let sessionID = UUID()
            let manifest = endedTestManifest(
                sessionID: sessionID,
                storePath: "/tmp/ended-session-not-on-disk.wax"
            )
            let ended = InMemoryEndedSessionStore(
                manifests: [manifest],
                searchHits: [
                    sessionID: [
                        LayeredRecall.EpisodicLaneHit(
                            frameID: 42,
                            score: 0.91,
                            previewText: "in-memory episode note",
                            metadata: [:],
                            explanations: [],
                            canonicalFrameID: 42
                        )
                    ]
                ]
            )
            let stores = LayeredRecall.Stores(
                longTermMemory: longTerm,
                workingLane: { _ in nil },
                inferWriteScope: { _, _ in LayeredRecall.Identity() },
                preview: { $0 ?? "" },
                canonicalFrameID: { frameID, _ in frameID },
                endedSessions: ended,
                nowMs: { 0 }
            )

            let hits = try await LayeredRecall.search(
                request: LayeredRecall.SearchRequest(
                    query: "episode",
                    mode: .textOnly,
                    topK: 5,
                    horizons: .episodic
                ),
                stores: stores
            )
            #expect(hits.contains { $0.text.contains("in-memory episode note") })
            #expect(hits.contains { $0.id == .episodic(sessionID: sessionID, frameID: 42) })
            try await longTerm.close()
        } catch {
            try? await longTerm.close()
            throw error
        }
    }
}

private func withEndedSessionDisk(
    _ body: (DiskEndedSessionStore, BrokerSessionManifest, String) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-ended-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let storeURL = root.appendingPathComponent("\(sessionID.uuidString).wax")
    let token = "ENDED-SESSION-\(UUID().uuidString.prefix(8))"

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    let writer = try await MemoryOrchestrator(at: storeURL, config: config)
    _ = try await writer.remember(token)
    try await writer.flush()
    try await writer.close()

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let manifest = BrokerSessionManifest(
        sessionID: sessionID,
        agentID: "ended-agent",
        runID: "ended-run",
        project: "Wax",
        repo: "Wax",
        storePath: storeURL.path,
        eventLogPath: BrokerSessionPersistence.eventLogURL(rootURL: root, sessionID: sessionID).path,
        status: .ended,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
        endedAtMs: nowMs
    )
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: root, sessionID: sessionID)
    )

    let store = DiskEndedSessionStore(
        sessionRootURL: root,
        noEmbedder: true,
        enableAccessStatsScoring: false,
        readiness: EmbeddingReadiness()
    )
    try await body(store, manifest, token)
}

private func endedTestManifest(sessionID: UUID, storePath: String) -> BrokerSessionManifest {
    BrokerSessionManifest(
        sessionID: sessionID,
        agentID: "ended-agent",
        runID: "ended-run",
        project: "Wax",
        repo: "Wax",
        storePath: storePath,
        eventLogPath: "/tmp/ended-session-missing.events.jsonl",
        status: .ended,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: 1,
        updatedAtMs: 1,
        endedAtMs: 1
    )
}
