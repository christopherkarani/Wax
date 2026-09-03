import Foundation
import Testing
@testable import Wax

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
    #expect(selected.scopeDropped.hint == "pass scope=global for cross-project — do not auto-widen")
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
    #expect(selected.scopeDropped.top.map(\.preview) == ["foreign-2", "foreign-5", "foreign-8"])
    #expect(selected.scopeDropped.top.map(\.score) == [1.0, 1.0, 0.75])
}

@Test
func layeredRecallResolveIdentityPrefersExplicitThenSessionThenInferred() {
    let identity = LayeredRecall.resolveIdentity(
        explicitProject: nil,
        explicitRepo: "explicit-repo",
        sessionProject: "session-project",
        sessionRepo: "session-repo",
        inferred: LayeredRecall.Identity(project: "inferred-project", repo: "inferred-repo")
    )
    #expect(identity.project == "session-project")
    #expect(identity.repo == "explicit-repo")
}

@Test
func layeredRecallRetrievalTopKOverfetchesForProjectScope() {
    #expect(LayeredRecall.retrievalTopK(requested: 5, scope: .project) == 15)
    #expect(LayeredRecall.retrievalTopK(requested: 5, scope: .session) == 15)
    #expect(LayeredRecall.retrievalTopK(requested: 5, scope: .global) == 5)
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

    let global = LayeredRecall.frameFilterForScopedRetrieval(
        base: nil,
        scope: .global,
        identity: identity
    )
    #expect(global == nil)
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

private func layeredHit(
    frameID: UInt64,
    score: Float,
    text: String,
    horizon: LayeredRecall.Horizon,
    metadata: [String: String] = [:]
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
        timestampMs: 0
    )
}
