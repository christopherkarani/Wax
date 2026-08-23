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
func memoryReferenceWireValuePinsWireBytes() {
    let sessionID = UUID(uuidString: "DEADBEEF-1234-5678-90AB-CDEF01234567")!
    #expect(MemoryReference.durable(frameID: 42).wireValue == "durable:42")
    #expect(MemoryReference.working(sessionID: sessionID, frameID: 7).wireValue == "working:\(sessionID.uuidString):7")
    #expect(MemoryReference.working(sessionID: nil, frameID: 7).wireValue == "working:unknown:7")
    #expect(MemoryReference.episodic(sessionID: sessionID, frameID: 9).wireValue == "episodic:\(sessionID.uuidString):9")
}

@Test
func memoryReferenceParsingRoundTripsEveryProducedShape() {
    let sessionID = UUID()
    let shapes: [MemoryReference] = [
        .durable(frameID: 0),
        .durable(frameID: UInt64.max),
        .working(sessionID: nil, frameID: 0),
        .working(sessionID: nil, frameID: UInt64.max),
        .working(sessionID: sessionID, frameID: 7),
        .episodic(sessionID: nil, frameID: 9),
        .episodic(sessionID: sessionID, frameID: 9),
    ]
    for shape in shapes {
        #expect(
            MemoryReference(parsing: shape.wireValue) == shape,
            "round-trip failed for '\(shape.wireValue)'"
        )
    }
}

@Test
func memoryReferenceParsingRejectsMalformedLiterals() {
    let malformed = [
        "",
        ":",
        "durable",
        "durable:",
        "durable:x",
        "durable:-1",
        "durable:1:2",
        "bogus:1",
        "bogus:some-uuid:1",
        "working:1",
        "working:not-a-uuid:1",
        "working::1",
        "episodic:1:2:3",
    ]
    for raw in malformed {
        #expect(MemoryReference(parsing: raw) == nil, "expected \(raw) to be rejected")
    }
}

@Test
func memoryReferenceInitRejectsSessionOnDurableLane() {
    #expect(MemoryReference(horizon: .durable, sessionID: UUID(), frameID: 1) == nil)
    #expect(MemoryReference(horizon: .durable, sessionID: nil, frameID: 1) != nil)
    #expect(MemoryReference(horizon: .working, sessionID: nil, frameID: 1) != nil)
}

private func layeredHit(
    frameID: UInt64,
    score: Float,
    text: String,
    horizon: LayeredRecall.Horizon,
    metadata: [String: String] = [:]
) -> LayeredRecall.Hit {
    LayeredRecall.Hit(
        reference: MemoryReference(horizon: horizon, sessionID: nil, frameID: frameID)!,
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
