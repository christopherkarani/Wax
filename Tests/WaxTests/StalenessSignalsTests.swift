import Foundation
import Testing
@testable import Wax

private func stalenessHit(
    frameID: UInt64,
    score: Float,
    text: String,
    type: MemoryType,
    project: String? = nil,
    timestampMs: Int64 = 0,
    horizon: LayeredRecall.Horizon = .durable,
    durability: MemoryDurability? = nil
) -> LayeredRecall.Hit {
    var metadata = [MemoryMetadataKeys.type: type.rawValue]
    if let project {
        metadata[MemoryMetadataKeys.project] = project
    }
    if let durability {
        metadata[MemoryMetadataKeys.durability] = durability.rawValue
    }
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

@Test
func recallStaleHintFlagsOlderSameTypeHit() throws {
    let old = stalenessHit(frameID: 1, score: 0.9, text: "old decision", type: .decision, timestampMs: 1_000)
    let new = stalenessHit(frameID: 2, score: 0.8, text: "new decision", type: .decision, timestampMs: 2_000)
    #expect(RecallPresent.staleHints(for: [old, new]) == [true, false])
    #expect(RecallPresent.staleHints(for: [new]) == [false])

    let flagged = try #require(
        RecallPresent.renderRecallHit(old, rank: 2, verbose: false, nowMs: 3_000, staleHint: true).objectValue
    )
    #expect(flagged["stale_hint"]?.boolValue == true)
    let clean = try #require(
        RecallPresent.renderRecallHit(new, rank: 1, verbose: false, nowMs: 3_000).objectValue
    )
    #expect(clean["stale_hint"] == nil)
}

@Test
func recallStaleHintIgnoresDifferentType() {
    let old = stalenessHit(frameID: 1, score: 0.9, text: "old decision", type: .decision, timestampMs: 1_000)
    let new = stalenessHit(frameID: 2, score: 0.8, text: "new fact", type: .fact, timestampMs: 2_000)
    #expect(RecallPresent.staleHints(for: [old, new]) == [false, false])
}

@Test
func mergeHitsDemotesSupersededButUnmarkedNearTwin() {
    // 11/12 Jaccard ≈ 0.917, above the 0.88 auto-supersede threshold, but the
    // cross-lane pair was never marked, so both reach the merge.
    let oldText = "Prefer project-scoped recall and never auto-widen an empty project lane."
    let newText = "Prefer project-scoped recall and never auto-widen an empty project lane now."
    let dayMs: Int64 = 24 * 60 * 60 * 1_000
    let old = stalenessHit(
        frameID: 1, score: 0.90, text: oldText, type: .decision,
        project: "Wax", timestampMs: 1_000, horizon: .durable
    )
    let new = stalenessHit(
        frameID: 2, score: 0.80, text: newText, type: .decision,
        project: "Wax", timestampMs: 2_000, horizon: .working
    )
    let merged = LayeredRecall.mergeHits(
        sessionHits: [new], durableHits: [old], limit: 2, nowMs: 60 * dayMs
    )
    #expect(merged.count == 2)
    #expect(merged[0].text == newText)
    #expect(merged[1].text == oldText)
    #expect(merged[1].explanations.contains(LayeredRecall.staleTwinExplanation))
    #expect(merged[0].explanations.contains(LayeredRecall.staleTwinExplanation) == false)
}

@Test
func staleTwinDemotionSkipsLockedAndForeignProjectFrames() {
    let oldText = "Prefer project-scoped recall and never auto-widen an empty project lane."
    let newText = "Prefer project-scoped recall and never auto-widen an empty project lane now."
    let locked = stalenessHit(
        frameID: 1, score: 0.9, text: oldText, type: .decision,
        project: "Wax", timestampMs: 1_000, durability: .locked
    )
    let foreign = stalenessHit(
        frameID: 3, score: 0.9, text: oldText, type: .decision,
        project: "Other", timestampMs: 1_000
    )
    let new = stalenessHit(
        frameID: 2, score: 0.8, text: newText, type: .decision,
        project: "Wax", timestampMs: 2_000
    )
    let demoted = LayeredRecall.demoteStaleNearTwins([locked, foreign, new])
    #expect(demoted[0].score == 0.9)
    #expect(demoted[0].explanations.isEmpty)
    #expect(demoted[1].score == 0.9)
    #expect(demoted[1].explanations.isEmpty)
    #expect(abs(demoted[2].score - 0.8) < 0.0001)
}

@Test
func primeStaleHintFlagsOlderSameTypeItem() throws {
    let envelope = MCPPrimeAssembly.assemble(
        MCPPrimeAssembly.Input(
            host: "claude",
            includePerson: false,
            projectMiss: false,
            project: "Wax",
            repo: "Wax",
            personCandidates: [],
            projectCandidates: [
                MCPPrimeAssembly.Candidate(
                    text: "old decision", memoryType: "decision",
                    project: "Wax", repo: "Wax", score: 0.9, createdAtMs: 1_000
                ),
                MCPPrimeAssembly.Candidate(
                    text: "new decision", memoryType: "decision",
                    project: "Wax", repo: "Wax", score: 0.8, createdAtMs: 9_000
                ),
            ],
            handoff: nil
        ),
        tokenizer: .character,
        nowMs: 10_000
    )
    let old = try #require(envelope.projectItems.first { $0.text == "old decision" })
    let new = try #require(envelope.projectItems.first { $0.text == "new decision" })
    #expect(old.staleHint == true)
    #expect(new.staleHint == false)
    #expect(envelope.renderedJSON.contains("\"stale_hint\":true"))
    #expect(envelope.hostContext.contains("stale"))
}

@Test
func reviewQueueFrameMatchesUnreviewedDecisionsAndConstraints() {
    #expect(AgentBrokerService.isReviewQueueFrame([MemoryMetadataKeys.type: "decision"]) == true)
    #expect(AgentBrokerService.isReviewQueueFrame([MemoryMetadataKeys.type: "constraint"]) == true)
    #expect(
        AgentBrokerService.isReviewQueueFrame([
            MemoryMetadataKeys.type: "decision",
            MemoryMetadataKeys.reviewed: "true",
        ]) == false
    )
    #expect(
        AgentBrokerService.isReviewQueueFrame([
            MemoryMetadataKeys.type: "constraint",
            MemoryMetadataKeys.reviewed: "false",
        ]) == true
    )
    #expect(AgentBrokerService.isReviewQueueFrame([MemoryMetadataKeys.type: "note"]) == false)
    #expect(AgentBrokerService.isReviewQueueFrame([MemoryMetadataKeys.type: "fact"]) == false)
    #expect(AgentBrokerService.isReviewQueueFrame([:]) == false)
}

private func withStalenessBroker<T>(
    _ body: (AgentBrokerService) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-staleness-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableTextSearch = true
    config.rag.searchMode = .hybrid(alpha: 0.5)
    config.liveSetRewriteSchedule = .disabled

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: config
    )
    do {
        let result = try await body(service)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func stalenessRemember(
    _ service: AgentBrokerService,
    content: String,
    memoryType: String,
    reviewed: Bool = false
) async throws {
    var arguments: [String: AgentBrokerValue] = [
        "content": .string(content),
        "memory_type": .string(memoryType),
        "durability": .string("durable"),
        "project": .string("WaxStaleness"),
        "repo": .string("WaxStaleness"),
    ]
    if reviewed {
        arguments["reviewed"] = .bool(true)
    }
    let write = await service.handle(.init(command: "remember", arguments: arguments))
    #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
}

@Test
func statsReviewQueueDepthCountsUnreviewedDecisionsAndConstraints() async throws {
    try await withStalenessBroker { service in
        let empty = await service.handle(.init(command: "stats"))
        #expect(empty.ok == true)
        #expect(try #require(empty.payload?.objectValue)["review_queue_depth"]?.intValue == 0)

        try await stalenessRemember(service, content: "staleness unreviewed decision", memoryType: "decision")
        try await stalenessRemember(
            service, content: "staleness reviewed constraint", memoryType: "constraint", reviewed: true
        )
        try await stalenessRemember(service, content: "staleness unreviewed note", memoryType: "note")
        try await stalenessRemember(
            service, content: "staleness reviewed decision", memoryType: "decision", reviewed: true
        )

        let stats = await service.handle(.init(command: "stats"))
        #expect(stats.ok == true)
        #expect(try #require(stats.payload?.objectValue)["review_queue_depth"]?.intValue == 1)
    }
}
