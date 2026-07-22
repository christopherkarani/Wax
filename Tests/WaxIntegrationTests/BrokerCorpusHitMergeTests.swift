import Foundation
import Testing
import Wax

// MARK: - Helpers

private func hit(
    frameId: UInt64,
    score: Float,
    preview: String = "preview",
    sourcePath: String = "/corpus/a.wax",
    sources: [String] = ["text"],
    metadata: [String: String] = [:],
    dedupeKey: String? = nil
) -> BrokerCorpusMergeHit {
    let key = dedupeKey ?? BrokerCorpusMergeHit.makeDedupeKey(
        sourcePath: sourcePath,
        frameId: frameId,
        preview: preview
    )
    return BrokerCorpusMergeHit(
        frameId: frameId,
        score: score,
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
                metadata: [
                    BrokerCorpusMetadataKeys.origin: "active_session",
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
    #expect(merged[0].metadata[BrokerCorpusMetadataKeys.origin] == "active_session")
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
        metadata: [BrokerCorpusMetadataKeys.origin: "active_session"]
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
    #expect(annotated[BrokerCorpusMetadataKeys.origin] == "active_session")
    #expect(annotated[BrokerCorpusMetadataKeys.sourceStorePath] == "/sessions/abc.wax")
    #expect(annotated[BrokerCorpusMetadataKeys.sourceStoreName] == "abc.wax")
    #expect(annotated[BrokerCorpusMetadataKeys.sourceFrameID] == "99")
    #expect(annotated["session_id"] == "11111111-2222-3333-4444-555555555555")
}
