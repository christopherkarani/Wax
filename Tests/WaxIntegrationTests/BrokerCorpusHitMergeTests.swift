import Foundation
import Testing
import Wax

// MARK: - Helpers

private func hit(
    frameId: UInt64,
    score: Float,
    preview: String = "preview",
    sourcePath: String = "/corpus/a.wax",
    origin: CorpusOrigin = .sessionStore,
    sources: [RAGContext.Source] = [.text],
    metadata: [String: String] = [:],
    dedupeKey: String? = nil
) -> BrokerCorpusMergeHit {
    var metadata = metadata
    if metadata[BrokerCorpusMetadataKeys.sourceStorePath] == nil {
        metadata[BrokerCorpusMetadataKeys.sourceStorePath] = sourcePath
    }
    let key = dedupeKey ?? BrokerCorpusMergeHit.makeDedupeKey(
        sourcePath: sourcePath,
        frameId: frameId,
        preview: preview
    )
    return BrokerCorpusMergeHit(
        frameId: frameId,
        score: score,
        origin: origin,
        sources: sources,
        preview: preview,
        metadata: metadata,
        dedupeKey: key
    )
}

// MARK: - Merge of active-session hits

@Test
func brokerCorpusMergeIncludesActiveSessionHits() {
    let corpus = [
        hit(frameId: 1, score: 0.5, preview: "disk-only", sourcePath: "/disk/s1.wax"),
    ]
    let active = [
        [
            hit(
                frameId: 2,
                score: 0.9,
                preview: "live session note",
                sourcePath: "/sessions/active.wax",
                origin: .activeSession,
                metadata: [
                    "session_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                ]
            ),
        ],
    ]

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: corpus,
        activeSessionHitGroups: active,
        topK: 10
    )

    #expect(merged.count == 2)
    #expect(merged[0].frameId == 2)
    #expect(merged[0].score == 0.9)
    #expect(merged[0].origin == .activeSession)
    #expect(merged[0].metadata[BrokerCorpusMetadataKeys.origin] == CorpusOrigin.activeSession.rawValue)
    #expect(merged[1].frameId == 1)
}

@Test
func brokerCorpusMergePreservesActiveSessionGroupOrderForDedupeFirstWins() {
    // Same dedupe key across two sessions: first group wins (caller sorts sessions).
    let key = BrokerCorpusMergeHit.makeDedupeKey(
        sourcePath: "/sessions/shared.wax",
        frameId: 7,
        preview: "same"
    )
    let first = hit(
        frameId: 7,
        score: 0.4,
        preview: "same",
        sourcePath: "/sessions/shared.wax",
        metadata: ["winner": "first"],
        dedupeKey: key
    )
    let second = hit(
        frameId: 7,
        score: 0.99,
        preview: "same",
        sourcePath: "/sessions/shared.wax",
        metadata: ["winner": "second"],
        dedupeKey: key
    )

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: [],
        activeSessionHitGroups: [[first], [second]],
        topK: 5
    )

    #expect(merged.count == 1)
    #expect(merged[0].metadata["winner"] == "first")
    // Higher score on the discarded duplicate must not surface.
    #expect(merged[0].score == 0.4)
}

// MARK: - Dedupe key prevents duplicates

@Test
func brokerCorpusMergeDedupeKeyDropsActiveDuplicateOfCorpusHit() {
    let path = "/sessions/s1.wax"
    let preview = "shared content"
    let corpusHit = hit(frameId: 10, score: 0.6, preview: preview, sourcePath: path, metadata: ["origin": "disk"])
    let activeHit = hit(
        frameId: 10,
        score: 0.95,
        preview: preview,
        sourcePath: path,
        origin: .activeSession,
        metadata: [BrokerCorpusMetadataKeys.origin: CorpusOrigin.activeSession.rawValue]
    )

    #expect(corpusHit.dedupeKey == activeHit.dedupeKey)

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: [corpusHit],
        activeSessionHitGroups: [[activeHit]],
        topK: 10
    )

    #expect(merged.count == 1)
    #expect(merged[0].metadata["origin"] == "disk")
    #expect(merged[0].score == 0.6)
}

@Test
func brokerCorpusMergeDedupeKeyAllowsDifferentFrameOrPreview() {
    let path = "/sessions/s1.wax"
    let corpus = [
        hit(frameId: 1, score: 0.5, preview: "alpha", sourcePath: path),
    ]
    let active = [
        [
            hit(frameId: 1, score: 0.7, preview: "beta", sourcePath: path),
            hit(frameId: 2, score: 0.6, preview: "alpha", sourcePath: path),
        ],
    ]

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: corpus,
        activeSessionHitGroups: active,
        topK: 10
    )

    #expect(merged.count == 3)
    #expect(Set(merged.map(\.dedupeKey)).count == 3)
}

@Test
func brokerCorpusMergeDedupeKeyFormatIsStable() {
    let key = BrokerCorpusMergeHit.makeDedupeKey(
        sourcePath: "/tmp/store.wax",
        frameId: 42,
        preview: "hello#world"
    )
    #expect(key == "/tmp/store.wax#42#hello#world")
}

// MARK: - topK after score sort

@Test
func brokerCorpusMergeTopKAfterScoreSort() {
    let corpus = [
        hit(frameId: 1, score: 0.3, preview: "low", sourcePath: "/a"),
        hit(frameId: 2, score: 0.8, preview: "high-disk", sourcePath: "/a"),
    ]
    let active = [
        [
            hit(frameId: 3, score: 0.9, preview: "highest", sourcePath: "/b"),
            hit(frameId: 4, score: 0.5, preview: "mid", sourcePath: "/b"),
            hit(frameId: 5, score: 0.1, preview: "lowest", sourcePath: "/b"),
        ],
    ]

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: corpus,
        activeSessionHitGroups: active,
        topK: 2
    )

    #expect(merged.count == 2)
    #expect(merged[0].frameId == 3)
    #expect(merged[0].score == 0.9)
    #expect(merged[1].frameId == 2)
    #expect(merged[1].score == 0.8)
}

@Test
func brokerCorpusMergeScoreTiesBreakByFrameIdAscending() {
    let corpus = [
        hit(frameId: 30, score: 0.5, preview: "a", sourcePath: "/x"),
        hit(frameId: 10, score: 0.5, preview: "b", sourcePath: "/x"),
        hit(frameId: 20, score: 0.5, preview: "c", sourcePath: "/x"),
    ]

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: corpus,
        activeSessionHitGroups: [],
        topK: 10
    )

    #expect(merged.map(\.frameId) == [10, 20, 30])
}

@Test
func brokerCorpusMergeTopKZeroYieldsEmpty() {
    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: [hit(frameId: 1, score: 1.0)],
        activeSessionHitGroups: [],
        topK: 0
    )
    #expect(merged.isEmpty)
}

// MARK: - active_sessions_searched (caller-exposed count)

@Test
func brokerCorpusMergeActiveSessionsSearchedCountMatchesGroups() {
    // Production path reports active_sessions_searched from orderedActiveSessions.count
    // (one group per session, including empty hit groups). Mirror that contract here.
    let emptySession: [BrokerCorpusMergeHit] = []
    let hitSession = [hit(frameId: 1, score: 0.7, preview: "live", sourcePath: "/s")]
    let groups = [emptySession, hitSession, emptySession]
    let activeSessionsSearched = groups.count

    let merged = BrokerCorpusHitMerge.merge(
        corpusHits: [],
        activeSessionHitGroups: groups,
        topK: 5
    )

    #expect(activeSessionsSearched == 3)
    #expect(merged.count == 1)
    #expect(merged[0].frameId == 1)
}

// MARK: - Active-session metadata annotation

@Test
func brokerCorpusAnnotateActiveSessionMetadata() {
    let base = ["existing": "keep", BrokerCorpusMetadataKeys.sourceRole: "user"]
    let annotated = BrokerCorpusHitMerge.annotateActiveSessionMetadata(
        base: base,
        storePath: "/sessions/abc.wax",
        storeName: "abc.wax",
        frameId: 99,
        sessionID: "11111111-2222-3333-4444-555555555555"
    )

    #expect(annotated["existing"] == "keep")
    #expect(annotated[BrokerCorpusMetadataKeys.sourceRole] == "user")
    #expect(annotated[BrokerCorpusMetadataKeys.origin] == CorpusOrigin.activeSession.rawValue)
    #expect(annotated[BrokerCorpusMetadataKeys.sourceStorePath] == "/sessions/abc.wax")
    #expect(annotated[BrokerCorpusMetadataKeys.sourceStoreName] == "abc.wax")
    #expect(annotated[BrokerCorpusMetadataKeys.sourceFrameID] == "99")
    #expect(annotated["session_id"] == "11111111-2222-3333-4444-555555555555")
}

// MARK: - CorpusOrigin store-boundary + exhaustive fetch (AC-004)

@Test
func brokerCorpusOriginDecodesHistoricalOnDiskStrings() {
    var sessionStore: [String: String] = [BrokerCorpusMetadataKeys.origin: "session_store"]
    #expect(CorpusOrigin.decode(from: &sessionStore, default: .longTerm) == .sessionStore)
    #expect(sessionStore[BrokerCorpusMetadataKeys.origin] == CorpusOrigin.sessionStore.rawValue)

    var active: [String: String] = [BrokerCorpusMetadataKeys.origin: "active_session"]
    #expect(CorpusOrigin.decode(from: &active, default: .sessionStore) == .activeSession)

    var longTerm: [String: String] = [BrokerCorpusMetadataKeys.origin: "long_term"]
    #expect(CorpusOrigin.decode(from: &longTerm, default: .sessionStore) == .longTerm)

    var missing: [String: String] = [:]
    #expect(CorpusOrigin.decode(from: &missing, default: .sessionStore) == .sessionStore)
    #expect(missing[BrokerCorpusMetadataKeys.origin] == "session_store")

    var unknown: [String: String] = [BrokerCorpusMetadataKeys.origin: "legacy_other"]
    #expect(CorpusOrigin.decode(from: &unknown, default: .sessionStore) == nil)
    #expect(unknown[BrokerCorpusMetadataKeys.origin] == "legacy_other")

    var empty: [String: String] = [BrokerCorpusMetadataKeys.origin: ""]
    #expect(CorpusOrigin.decode(from: &empty, default: .sessionStore) == nil)
    #expect(empty[BrokerCorpusMetadataKeys.origin] == "")
}

@Test
func brokerCorpusFromIndexedHitDefaultsMissingOriginToSessionStore() throws {
    let hit = try #require(BrokerCorpusMergeHit.fromIndexedHit(
        frameId: 4,
        score: 0.2,
        sources: [.text, .vector],
        preview: "on disk",
        metadata: [BrokerCorpusMetadataKeys.sourceStorePath: "/sessions/ended.wax"],
        defaultOrigin: .sessionStore
    ))
    #expect(hit.origin == .sessionStore)
    #expect(hit.sources == [.text, .vector])
    #expect(hit.metadata[BrokerCorpusMetadataKeys.origin] == CorpusOrigin.sessionStore.rawValue)
}

@Test
func brokerCorpusFromIndexedHitDropsUnknownOriginInsteadOfForgingSessionStore() {
    let metadata = [
        BrokerCorpusMetadataKeys.origin: "legacy_other",
        BrokerCorpusMetadataKeys.sourceStorePath: "/sessions/ended.wax",
    ]
    let hit = BrokerCorpusMergeHit.fromIndexedHit(
        frameId: 5,
        score: 0.2,
        sources: [.text],
        preview: "unknown writer",
        metadata: metadata,
        defaultOrigin: .sessionStore
    )
    #expect(hit == nil)
}

@Test
func brokerCorpusFromIndexedHitExplicitOriginWinsOverUnknownMetadataString() {
    let hit = BrokerCorpusMergeHit.fromIndexedHit(
        frameId: 6,
        score: 0.3,
        sources: [.text],
        preview: "live long-term",
        metadata: [
            BrokerCorpusMetadataKeys.origin: "legacy_other",
            BrokerCorpusMetadataKeys.sourceStorePath: "/durable/memory.wax",
        ],
        origin: .longTerm
    )
    #expect(hit.origin == .longTerm)
    #expect(hit.metadata[BrokerCorpusMetadataKeys.origin] == CorpusOrigin.longTerm.rawValue)
}

@Test
func brokerCorpusSessionStoreOriginIsExplicitFetchCase() {
    let path = "/sessions/ended/store.wax"
    let sessionStoreHit = hit(
        frameId: 11,
        score: 0.4,
        preview: "ended session note",
        sourcePath: path,
        origin: .sessionStore
    )
    let longTermHit = hit(frameId: 12, score: 0.4, origin: .longTerm)
    let activeHit = hit(
        frameId: 13,
        score: 0.4,
        origin: .activeSession,
        metadata: ["session_id": "11111111-2222-3333-4444-555555555555"]
    )

    switch sessionStoreHit.fetchCase {
    case .sessionStore(let url):
        #expect(url.path == URL(fileURLWithPath: path).standardizedFileURL.path)
    case .longTerm, .activeSession, nil:
        Issue.record("sessionStore origin must resolve as an explicit trusted-store fetch")
    }

    switch longTermHit.fetchCase {
    case .longTerm:
        break
    case .activeSession, .sessionStore, nil:
        Issue.record("longTerm origin must stay a live long-term fetch case")
    }

    switch activeHit.fetchCase {
    case .activeSession(let sessionID):
        #expect(sessionID == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    case .longTerm, .sessionStore, nil:
        Issue.record("activeSession origin must stay a live session fetch case")
    }

    #expect(sessionStoreHit.origin == .sessionStore)
    #expect(sessionStoreHit.origin.rawValue == "session_store")

    let missingPath = BrokerCorpusMergeHit(
        frameId: 14,
        score: 0.4,
        origin: .sessionStore,
        sources: [.text],
        preview: "ended session without source path",
        metadata: [:],
        dedupeKey: "nopath"
    )
    #expect(missingPath.fetchCase == nil)
}

@Test
func brokerRecallAllowsCorpusSearchHitKeepsActiveSessionWhenIdentityUnresolved() {
    let identity = LayeredRecall.Identity()
    let live = hit(
        frameId: 1,
        score: 1,
        preview: "live working",
        origin: .activeSession,
        metadata: [
            MemoryMetadataKeys.project: "ForeignLab",
            MemoryMetadataKeys.repo: "ForeignLab",
        ]
    )
    let unstamped = hit(frameId: 2, score: 1, preview: "unstamped durable", origin: .longTerm)
    let foreign = hit(
        frameId: 3,
        score: 1,
        preview: "ForeignLab durable",
        origin: .longTerm,
        metadata: [
            MemoryMetadataKeys.project: "ForeignLab",
            MemoryMetadataKeys.repo: "ForeignLab",
        ]
    )
    let ended = hit(
        frameId: 4,
        score: 1,
        preview: "ended session store",
        origin: .sessionStore,
        metadata: [
            MemoryMetadataKeys.project: "ForeignLab",
            MemoryMetadataKeys.repo: "ForeignLab",
        ]
    )

    #expect(BrokerRecall.allowsCorpusSearchHit(live, identity: identity))
    #expect(BrokerRecall.allowsCorpusSearchHit(unstamped, identity: identity))
    #expect(BrokerRecall.allowsCorpusSearchHit(foreign, identity: identity) == false)
    #expect(BrokerRecall.allowsCorpusSearchHit(ended, identity: identity) == false)
}
