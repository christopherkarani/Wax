import Foundation
import Testing
@testable import Wax

@Test
func compactAssemblyPackKeepsHorizonBuckets() async {
    let working = compactHit(frameID: 1, text: "live note", horizon: .working)
    let episodic = compactHit(frameID: 2, text: "ended note", horizon: .episodic)
    let durable = compactHit(frameID: 3, text: "durable note", horizon: .durable)

    let packed = await CompactAssembly.pack(
        query: "q",
        working: [working],
        episodic: [episodic],
        durable: [durable],
        tokenBudget: 10_000,
        maxItems: 4,
        tokenizer: .character
    )

    #expect(packed.short.map(\.frameID) == [1])
    #expect(packed.medium.map(\.frameID) == [2])
    #expect(packed.long.map(\.frameID) == [3])
    #expect(packed.compactedText.contains("Short-Term Context"))
    #expect(packed.compactedText.contains("Medium-Term Context"))
    #expect(packed.compactedText.contains("Long-Term Context"))
    #expect(packed.summary.contains("live note"))
    #expect(packed.summary.contains("ended note"))
    #expect(packed.summary.contains("durable note"))
}

@Test
func compactAssemblyPackSkipsHitsThatExceedBudgetThenContinues() async {
    let oversized = compactHit(frameID: 1, text: String(repeating: "x", count: 80), horizon: .working)
    let small = compactHit(frameID: 2, text: "ok", horizon: .working)
    let packed = await CompactAssembly.pack(
        query: "q",
        working: [oversized, small],
        episodic: [],
        durable: [],
        tokenBudget: 50,
        maxItems: 4,
        tokenizer: .character
    )

    #expect(packed.short.map(\.frameID) == [2])
    #expect(packed.usedTokens <= 50)
    #expect(packed.compactedText.contains("ok"))
    #expect(!packed.compactedText.contains(String(repeating: "x", count: 80)))
}

@Test
func compactAssemblyPackEmptyLanesYieldDefaultSummary() async {
    let packed = await CompactAssembly.pack(
        query: "q",
        working: [],
        episodic: [],
        durable: [],
        tokenBudget: 128,
        maxItems: 4,
        tokenizer: .character
    )

    #expect(packed.short.isEmpty)
    #expect(packed.medium.isEmpty)
    #expect(packed.long.isEmpty)
    #expect(packed.summary == "No compacted context available.")
    #expect(packed.compactedText.hasPrefix("Query: q"))
}

@Test
func compactAssemblyPackDedupesByReference() async {
    let first = compactHit(frameID: 1, text: "one", horizon: .durable, score: 0.9)
    var duplicate = compactHit(frameID: 1, text: "one-dup", horizon: .durable, score: 0.2)
    duplicate.id = first.id

    let packed = await CompactAssembly.pack(
        query: "q",
        working: [],
        episodic: [],
        durable: [first, duplicate],
        tokenBudget: 10_000,
        maxItems: 4,
        tokenizer: .character
    )

    #expect(packed.long.map(\.text) == ["one"])
}

@Test
func compactAssemblyPackCapsEachLaneAtMaxItems() async {
    let working = (1...6).map { compactHit(frameID: UInt64($0), text: "w\($0)", horizon: .working) }
    let packed = await CompactAssembly.pack(
        query: "q",
        working: working,
        episodic: [],
        durable: [],
        tokenBudget: 10_000,
        maxItems: 2,
        tokenizer: .character
    )

    #expect(packed.short.map(\.frameID) == [1, 2])
}

@Test
func layeredRecallEpisodicManifestsKeepEndedPeersAndDropCurrent() {
    let current = UUID()
    let endedPeer = UUID()
    let otherAgent = UUID()
    let manifests = [
        compactManifest(sessionID: current, agentID: "a", status: .active),
        compactManifest(sessionID: endedPeer, agentID: "a", status: .ended),
        compactManifest(sessionID: otherAgent, agentID: "b", status: .ended),
    ]

    let withSession = LayeredRecall.episodicManifests(
        from: manifests,
        currentSessionID: current,
        currentAgentID: "a"
    )
    #expect(withSession.map(\.sessionID) == [endedPeer])

    let unscoped = LayeredRecall.episodicManifests(
        from: manifests,
        currentSessionID: nil,
        currentAgentID: nil
    )
    #expect(Set(unscoped.map(\.sessionID)) == [endedPeer, otherAgent])
}

@Test
func layeredRecallEpisodicManifestsDropReclaimedTombstones() {
    let liveEnded = UUID()
    let reclaimed = UUID()
    let manifests = [
        compactManifest(sessionID: liveEnded, agentID: "a", status: .ended),
        compactManifest(sessionID: reclaimed, agentID: "a", status: .ended, reclaimedAtMs: 99),
    ]

    let selected = LayeredRecall.episodicManifests(
        from: manifests,
        currentSessionID: nil,
        currentAgentID: nil
    )
    #expect(selected.map(\.sessionID) == [liveEnded])
}

@Test
func compactAssemblyFetchSearchTopKStaysUninflated() {
    #expect(CompactAssembly.fetchSearchTopK(maxItems: 8) == 4)
    #expect(CompactAssembly.fetchSearchTopK(maxItems: 1) == 1)
    #expect(CompactAssembly.fetchSearchTopK(maxItems: 4) == 4)
    #expect(LayeredRecall.retrievalTopK(requested: 4, scope: .project) == 12)
}

private func compactHit(
    frameID: UInt64,
    text: String,
    horizon: LayeredRecall.Horizon,
    score: Float = 1
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
        metadata: [:],
        explanations: ["why"],
        timestampMs: 0
    )
}

private func compactManifest(
    sessionID: UUID,
    agentID: String,
    status: BrokerSessionManifest.Status,
    reclaimedAtMs: Int64? = nil
) -> BrokerSessionManifest {
    BrokerSessionManifest(
        sessionID: sessionID,
        agentID: agentID,
        runID: "run",
        project: nil,
        repo: nil,
        storePath: "/tmp/\(sessionID.uuidString).wax",
        eventLogPath: "/tmp/\(sessionID.uuidString).log",
        status: status,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: 0,
        updatedAtMs: 0,
        lastCheckpointAtMs: nil,
        checkpointCount: 0,
        lastHandoffAtMs: nil,
        lastCompactionAtMs: nil,
        latestSummary: nil,
        latestHandoff: nil,
        reclaimedAtMs: reclaimedAtMs
    )
}
