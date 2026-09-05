import Foundation
import Testing
@testable import Wax

@Suite("LayeredRecallTests")
struct LayeredRecallTests {
    @Test
    func layeredRecallMergeReservesMissingSessionHorizonWhenDurableFillsLimit() {
        let durable = (1...5).map { index in
            layeredHit(frameID: UInt64(index), score: 1.0 - Float(index) * 0.01, text: "durable hit \(index)", horizon: .durable)
        }
        let session = [
            layeredHit(frameID: 99, score: 0.05, text: "session reserved note", horizon: .working)
        ]
        let merged = LayeredRecall.mergeHits(sessionHits: session, durableHits: durable, limit: 5)
        #expect(merged.count == 5)
        #expect(merged.contains { $0.text.contains("session reserved note") })
        #expect(merged.contains { $0.explanations.contains("current session") })
        #expect(merged.contains { $0.explanations.contains("durable memory") })
    }

    @Test
    func layeredRecallMergeReservesMissingDurableHorizonWhenSessionFillsLimit() {
        let session = (1...5).map { index in
            layeredHit(frameID: UInt64(index), score: 1.0 - Float(index) * 0.01, text: "session hit \(index)", horizon: .working)
        }
        let durable = [
            layeredHit(frameID: 99, score: 0.05, text: "durable reserved note", horizon: .durable)
        ]
        let merged = LayeredRecall.mergeHits(sessionHits: session, durableHits: durable, limit: 5)
        #expect(merged.count == 5)
        #expect(merged.contains { $0.text.contains("durable reserved note") })
        #expect(merged.contains { $0.explanations.contains("current session") })
        #expect(merged.contains { $0.explanations.contains("durable memory") })
    }

    @Test
    func layeredRecallMergeKeepsFreshnessAdjustmentOnReservedStaleDurableHit() throws {
        let nowMs: Int64 = 2_000_000_000_000
        let session = (1...5).map { index in
            layeredHit(
                frameID: UInt64(index),
                score: 1.0 - Float(index) * 0.01,
                text: "session hit \(index)",
                horizon: .working,
                timestampMs: nowMs
            )
        }
        let durable = [
            layeredHit(
                frameID: 99,
                score: 0.20,
                text: "stale durable operational note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.type: MemoryType.taskState.rawValue],
                timestampMs: nowMs - 30 * 86_400_000
            )
        ]

        let merged = LayeredRecall.mergeHits(
            sessionHits: session,
            durableHits: durable,
            limit: 5,
            nowMs: nowMs
        )

        let reserved = try #require(merged.first { $0.frameID == 99 })
        #expect(abs(reserved.score - 0.02) < 0.0001)
        #expect(reserved.explanations.contains("durable memory"))
        #expect(reserved.explanations.contains("freshness adjusted operational memory"))
    }

    @Test
    func layeredRecallFreshnessDemotesStaleOperationalNoiseAndExposesRankScore() throws {
        let nowMs: Int64 = 2_000_000_000_000
        let oldOperational = layeredHit(
            frameID: 1,
            score: 0.92,
            text: "old CI failure dump",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.taskState.rawValue],
            timestampMs: nowMs - 15 * 86_400_000
        )
        let freshCorrection = layeredHit(
            frameID: 2,
            score: 0.88,
            text: "current CI baseline correction",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: nowMs - 86_400_000
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [oldOperational, freshCorrection],
            limit: 2,
            nowMs: nowMs
        )
        #expect(merged.map(\.text) == ["current CI baseline correction", "old CI failure dump"])
        #expect(merged[0].score > merged[1].score)
        #expect(merged[1].explanations.contains("freshness adjusted operational memory"))
    }

    @Test
    func layeredRecallFreshnessNeverAgesStandingPreferences() {
        let nowMs: Int64 = 2_000_000_000_000
        let oldPreference = layeredHit(
            frameID: 1,
            score: 0.92,
            text: "standing user preference",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.userPreference.rawValue],
            timestampMs: nowMs - 180 * 86_400_000
        )
        let freshNote = layeredHit(
            frameID: 2,
            score: 0.88,
            text: "fresh incidental note",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: nowMs - 86_400_000
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [freshNote, oldPreference],
            limit: 2,
            nowMs: nowMs
        )
        #expect(merged.first?.text == "standing user preference")
        #expect(merged.first?.score == 0.92)
    }

    @Test(arguments: [
        MemoryType.fact,
        MemoryType.lesson,
        MemoryType.userPreference,
        MemoryType.decision,
        MemoryType.constraint,
    ])
    func layeredRecallFreshnessNeverAgesStandingMemoryType(_ type: MemoryType) {
        let nowMs: Int64 = 2_000_000_000_000
        let hit = layeredHit(
            frameID: 1,
            score: 0.92,
            text: "standing \(type.rawValue)",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: type.rawValue],
            timestampMs: nowMs - 180 * 86_400_000
        )
        #expect(LayeredRecall.freshnessAdjustedScore(hit, nowMs: nowMs) == 0.92)
    }

    @Test(arguments: [MemoryType.note, MemoryType.taskState, MemoryType.handoff])
    func layeredRecallFreshnessDemotesUnreviewedUnlockedOperationalMemory(_ type: MemoryType) {
        let nowMs: Int64 = 2_000_000_000_000
        let hit = layeredHit(
            frameID: 1,
            score: 0.92,
            text: "stale \(type.rawValue)",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: type.rawValue],
            timestampMs: nowMs - 30 * 86_400_000
        )
        #expect(abs(LayeredRecall.freshnessAdjustedScore(hit, nowMs: nowMs) - 0.74) < 0.0001)
    }

    @Test
    func layeredRecallFreshnessNeverAgesReviewedOrLockedOperationalMemory() {
        let nowMs: Int64 = 2_000_000_000_000
        let reviewed = layeredHit(
            frameID: 1,
            score: 0.92,
            text: "reviewed operational note",
            horizon: .durable,
            metadata: [
                MemoryMetadataKeys.type: MemoryType.note.rawValue,
                MemoryMetadataKeys.reviewed: "true",
            ],
            timestampMs: nowMs - 180 * 86_400_000
        )
        let locked = layeredHit(
            frameID: 2,
            score: 0.88,
            text: "locked operational task",
            horizon: .durable,
            metadata: [
                MemoryMetadataKeys.type: MemoryType.taskState.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
            ],
            timestampMs: nowMs - 180 * 86_400_000
        )
        #expect(LayeredRecall.freshnessAdjustedScore(reviewed, nowMs: nowMs) == 0.92)
        #expect(LayeredRecall.freshnessAdjustedScore(locked, nowMs: nowMs) == 0.88)
    }

    @Test
    func layeredRecallFreshnessDoesNotTreatUnknownTimestampAsAgeZero() {
        let nowMs: Int64 = 2_000_000_000_000
        let unknown = layeredHit(
            frameID: 1,
            score: 0.92,
            text: "legacy operational note",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: 0
        )
        #expect(LayeredRecall.freshnessAdjustedScore(unknown, nowMs: nowMs) == 0.92)
    }

    @Test
    func layeredRecallSelectHitsGlobalSkipsProjectFilter() {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1,
                text: "other project note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            )
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .global,
            identity: LayeredRecall.Identity(project: "wax", repo: nil)
        )
        #expect(selected.projectMiss == false)
        #expect(selected.hits.count == 1)
        #expect(selected.scopeMissMessage == nil)
        #expect(selected.scopeDropped.count == 0)
    }

    @Test
    func layeredRecallSelectHitsProjectFiltersAndReportsMiss() {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1,
                text: "other project note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            )
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .project,
            identity: LayeredRecall.Identity(project: "wax", repo: nil)
        )
        #expect(selected.hits.isEmpty)
        #expect(selected.projectMiss == true)
        #expect(selected.scopeMissMessage == "no frames for project wax")
        #expect(selected.scopeDropped.count == 0)
        #expect(selected.scopeDropped.top.isEmpty)
        #expect(selected.scopeDropped.hint.isEmpty)
    }

    @Test
    func layeredRecallSelectHitsUnresolvedIdentityKeepsWorkingLaneWithoutForeignDurable() {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1.0,
                text: "foreign durable note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 2,
                score: 0.4,
                text: "live session note",
                horizon: .working
            ),
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .project,
            identity: LayeredRecall.Identity()
        )
        #expect(selected.projectMiss == false)
        #expect(selected.hits.map(\.text) == ["live session note"])
        #expect(selected.scopeDropped.count == 0)
        #expect(selected.scopeDropped.top.isEmpty)
    }

    @Test
    func layeredRecallSelectHitsUnresolvedIdentityKeepsUnstampedDurableWithWorkingLane() {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1.0,
                text: "foreign durable note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 3,
                score: 0.8,
                text: "unstamped durable fact",
                horizon: .durable
            ),
            layeredHit(
                frameID: 2,
                score: 0.4,
                text: "live session note",
                horizon: .working
            ),
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .project,
            identity: LayeredRecall.Identity()
        )
        #expect(selected.projectMiss == false)
        #expect(selected.hits.contains { $0.text == "live session note" })
        #expect(selected.hits.contains { $0.text == "unstamped durable fact" })
        #expect(!selected.hits.contains { $0.text == "foreign durable note" })
        #expect(selected.scopeDropped.count == 0)
    }

    @Test
    func layeredRecallProjectFilterKeepsUnstampedHitsForResolvedIdentity() {
        let hits = [
            layeredHit(
                frameID: 1,
                score: 1,
                text: "unstamped durable",
                horizon: .durable
            ),
            layeredHit(
                frameID: 2,
                score: 1,
                text: "home durable",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "Wax"]
            ),
            layeredHit(
                frameID: 3,
                score: 1,
                text: "foreign durable",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
        ]
        let filtered = LayeredRecall.filterHitsByProject(hits, project: "Wax", repo: nil)
        #expect(filtered.map(\.text) == ["unstamped durable", "home durable"])
    }

    @Test
    func layeredRecallSelectHitsUnresolvedIdentityWithoutWorkingLaneIsContentFreeMiss() {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1.0,
                text: "foreign durable note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .project,
            identity: LayeredRecall.Identity()
        )
        #expect(selected.hits.isEmpty)
        #expect(selected.projectMiss == true)
        #expect(selected.scopeDropped.count == 0)
        #expect(selected.scopeDropped.top.isEmpty)
    }

    @Test
    func layeredRecallSelectHitsProjectAnnouncesDroppedHigherForeignHits() throws {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1.0,
                text: "foreign high note",
                horizon: .durable,
                metadata: [
                    MemoryMetadataKeys.project: "other",
                    MemoryMetadataKeys.repo: "other-repo",
                ]
            ),
            layeredHit(
                frameID: 10,
                score: 0.5,
                text: "wax project note",
                horizon: .durable,
                metadata: [
                    MemoryMetadataKeys.project: "wax",
                    MemoryMetadataKeys.repo: "Wax",
                ]
            ),
            layeredHit(
                frameID: 3,
                score: 0.5,
                text: "foreign equal note",
                horizon: .durable,
                metadata: [
                    MemoryMetadataKeys.project: "other",
                    MemoryMetadataKeys.repo: "other-repo",
                ]
            ),
            layeredHit(
                frameID: 2,
                score: 0.25,
                text: "foreign low note",
                horizon: .durable,
                metadata: [
                    MemoryMetadataKeys.project: "other",
                    MemoryMetadataKeys.repo: "other-repo",
                ]
            ),
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .project,
            identity: LayeredRecall.Identity(project: "wax", repo: nil)
        )
        #expect(selected.projectMiss == false)
        #expect(selected.hits.count == 1)
        #expect(selected.hits.allSatisfy { $0.metadata[MemoryMetadataKeys.project] == "wax" })
        #expect(selected.scopeDropped.count >= 1)
        let top = try #require(selected.scopeDropped.top.first)
        #expect(top.project == "other")
        #expect(top.repo == "other-repo")
        #expect(top.score == 1.0)
        #expect(top.preview == "foreign high note")
        #expect(selected.scopeDropped.top.contains { $0.preview == "foreign equal note" })
        #expect(selected.scopeDropped.top.contains { $0.preview == "foreign low note" } == false)
        #expect(selected.scopeDropped.hint == "retry explicitly with scope=global")
    }

    @Test
    func layeredRecallSelectHitsSessionSkipsProjectFilter() {
        let merged = [
            layeredHit(
                frameID: 1,
                score: 1.0,
                text: "other project note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 10,
                score: 0.5,
                text: "wax project note",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "wax"]
            ),
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .session,
            identity: LayeredRecall.Identity(project: "wax", repo: nil)
        )
        #expect(selected.projectMiss == false)
        #expect(selected.hits.count == 2)
        #expect(selected.scopeMissMessage == nil)
        #expect(selected.scopeDropped.count == 0)
    }

    @Test
    func layeredRecallSelectHitsProjectDroppedTopCapsAtThreeSortedByScoreThenFrameID() {
        let merged = [
            layeredHit(
                frameID: 5,
                score: 1.0,
                text: "foreign-5",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 2,
                score: 1.0,
                text: "foreign-2",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 8,
                score: 0.75,
                text: "foreign-8",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 1,
                score: 0.5,
                text: "foreign-1",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "other"]
            ),
            layeredHit(
                frameID: 100,
                score: 0.25,
                text: "wax kept",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "wax"]
            ),
        ]
        let selected = LayeredRecall.selectHits(
            merged: merged,
            scope: .project,
            identity: LayeredRecall.Identity(project: "wax", repo: nil)
        )
        #expect(selected.projectMiss == false)
        #expect(selected.hits.map(\.text) == ["wax kept"])
        #expect(selected.scopeDropped.count == 4)
        #expect(selected.scopeDropped.top.map(\.preview) == ["foreign-5", "foreign-2", "foreign-8"])
        #expect(selected.scopeDropped.top.map(\.score) == [1.0, 1.0, 0.75])
    }

    @Test
    func layeredRecallResolveIdentityTreatsExplicitRepoAsTheOnlySelector() {
        let identity = LayeredRecall.resolveIdentity(
            explicitProject: nil,
            explicitRepo: "explicit-repo",
            sessionProject: "session-project",
            sessionRepo: "session-repo",
            inferred: LayeredRecall.Identity(project: "inferred-project", repo: "inferred-repo")
        )
        #expect(identity.project == nil)
        #expect(identity.repo == "explicit-repo")
    }

    @Test
    func layeredRecallResolveIdentityTreatsExplicitProjectAsTheOnlySelector() {
        let identity = LayeredRecall.resolveIdentity(
            explicitProject: "explicit-project",
            explicitRepo: nil,
            sessionProject: "session-project",
            sessionRepo: "session-repo",
            inferred: LayeredRecall.Identity(project: "inferred-project", repo: "inferred-repo")
        )
        #expect(identity.project == "explicit-project")
        #expect(identity.repo == nil)
    }

    @Test
    func layeredRecallProjectFilterRequiresBothExplicitSelectors() {
        let hits = [
            layeredHit(
                frameID: 1,
                score: 1,
                text: "same project wrong repo",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "Wax", MemoryMetadataKeys.repo: "Other"]
            ),
            layeredHit(
                frameID: 2,
                score: 1,
                text: "same project and repo",
                horizon: .durable,
                metadata: [MemoryMetadataKeys.project: "Wax", MemoryMetadataKeys.repo: "WaxRepo"]
            ),
        ]
        let filtered = LayeredRecall.filterHitsByProject(hits, project: "Wax", repo: "WaxRepo")
        #expect(filtered.map(\.frameID) == [2])
    }

    @Test
    func layeredRecallRetrievalTopKOverfetchesForProjectScope() {
        #expect(LayeredRecall.retrievalTopK(requested: 5, scope: .project) == 15)
        #expect(LayeredRecall.retrievalTopK(requested: 5, scope: .session) == 15)
        #expect(LayeredRecall.retrievalTopK(requested: 5, scope: .global) == 15)
        #expect(LayeredRecall.retrievalTopK(requested: 100, scope: .project, maxTopK: 200) == 200)
    }

    @Test
    func layeredRecallFrameFilterInjectsProjectMetadataForScopedRetrieval() {
        let identity = LayeredRecall.Identity(project: "Wax", repo: "Wax")
        let filter = LayeredRecall.frameFilterForScopedRetrieval(
            base: nil,
            scope: .project,
            identity: identity
        )
        #expect(filter?.metadataFilter?.requiredEntries[MemoryMetadataKeys.project] == "Wax")
        #expect(filter?.metadataFilter?.requiredEntries[MemoryMetadataKeys.repo] == "Wax")

        let global = LayeredRecall.frameFilterForScopedRetrieval(
            base: nil,
            scope: .global,
            identity: identity
        )
        #expect(global == nil)
    }

    @Test
    func layeredRecallMergeBreaksEqualScoresByNewestTimestamp() {
        let older = layeredHit(
            frameID: 1,
            score: 1,
            text: "older contract",
            horizon: .durable,
            timestampMs: 100
        )
        let newer = layeredHit(
            frameID: 2,
            score: 1,
            text: "newer correction",
            horizon: .durable,
            timestampMs: 200
        )
        let merged = LayeredRecall.mergeHits(sessionHits: [], durableHits: [older, newer], limit: 2)
        #expect(merged.map(\.text) == ["newer correction", "older contract"])
    }

    @Test
    func layeredRecallMakeMemoryReferenceFormatsHorizons() {
        let sessionID = UUID()
        #expect(LayeredRecall.makeMemoryReference(frameID: 42) == "durable:42")
        #expect(
            LayeredRecall.makeMemoryReference(.working, sessionID: sessionID, frameID: 7)
                == "working:\(sessionID.uuidString):7"
        )
    }

    @Test
    func layeredRecallHitMapsRAGItemKindAndSourcesWithoutStringRoundTrip() {
        let item = RAGContext.Item(
            kind: .snippet,
            frameId: 11,
            score: 1,
            sources: [.text],
            text: "hello"
        )
        let durable = LayeredRecall.hit(from: item)
        #expect(durable.kind == .snippet)
        #expect(durable.sources == [.text])
        let working = LayeredRecall.hit(from: item, horizon: .working, sessionID: UUID())
        #expect(working.kind == .snippet)
        #expect(working.sources == [.text])
    }

    @Test
    func layeredRecallHitTimestampUsesCreatedAtMsAndUnknownStaysZero() {
        let stamped = RAGContext.Item(
            kind: .snippet,
            frameId: 11,
            score: 1,
            sources: [.text],
            text: "hello",
            metadata: [MemoryMetadataKeys.createdAtMs: "1234"]
        )
        #expect(LayeredRecall.hit(from: stamped).timestampMs == 1234)

        let unknown = RAGContext.Item(
            kind: .snippet,
            frameId: 12,
            score: 1,
            sources: [.text],
            text: "legacy"
        )
        #expect(LayeredRecall.hit(from: unknown).timestampMs == 0)
    }
}

private func layeredHit(
    frameID: UInt64,
    score: Float,
    text: String,
    horizon: LayeredRecall.Horizon,
    metadata: [String: String] = [:],
    timestampMs: Int64 = 0
) -> LayeredRecall.Hit {
    let id: MemoryID
    switch horizon {
    case .durable:
        id = .durable(frameID: frameID)
    case .working:
        id = .working(sessionID: UUID(), frameID: frameID)
    case .episodic:
        id = .episodic(sessionID: UUID(), frameID: frameID)
    }
    return LayeredRecall.Hit(
        id: id,
        score: score,
        text: text,
        preview: text,
        metadata: metadata,
        explanations: [],
        timestampMs: timestampMs
    )
}
