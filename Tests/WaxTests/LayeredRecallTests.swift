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
func layeredRecallMakeMemoryReferenceFormatsHorizons() {
    let sessionID = UUID()
    #expect(LayeredRecall.makeMemoryReference(.durable, sessionID: nil, frameID: 42) == "durable:42")
    #expect(
        LayeredRecall.makeMemoryReference(.working, sessionID: sessionID, frameID: 7)
            == "working:\(sessionID.uuidString):7"
    )
}

private func layeredHit(
    frameID: UInt64,
    score: Float,
    text: String,
    horizon: LayeredRecall.Horizon,
    metadata: [String: String] = [:]
) -> LayeredRecall.Hit {
    LayeredRecall.Hit(
        reference: LayeredRecall.makeMemoryReference(horizon, sessionID: nil, frameID: frameID),
        horizon: horizon,
        frameID: frameID,
        score: score,
        text: text,
        preview: text,
        metadata: metadata,
        explanations: [],
        timestampMs: 0
    )
}
