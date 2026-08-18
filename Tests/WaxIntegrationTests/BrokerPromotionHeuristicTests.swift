import Foundation
import Testing
@testable import Wax

@Test
func promotionRejectsExplicitDoNotPromoteCanaryAfterOneRecall() {
    let proposal = BrokerMemoryInsights.proposePromotion(
        content: "Session-only note: do not promote. CLEAN-TOKEN-20260818",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
        ],
        sessionID: UUID(),
        sourceFrameID: 0,
        scope: nil,
        longTermDocuments: [],
        recallSignals: BrokerSessionRecallSignals(
            recallCount: 1,
            uniqueQueryCount: 1,
            lastRetrievedAtMs: 1,
            averageScore: 0.9
        )
    )
    #expect(proposal.shouldWrite == false)
    #expect(proposal.reasons.contains { $0.localizedCaseInsensitiveContains("do not promote") })
}

@Test
func promotionStillWritesCanonicalDecisionWithoutRecall() {
    let proposal = BrokerMemoryInsights.proposePromotion(
        content: "Decision: keep MiniLM as the default embedder for waxmcp.",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.decision.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
        ],
        sessionID: UUID(),
        sourceFrameID: 1,
        scope: nil,
        longTermDocuments: []
    )
    #expect(proposal.shouldWrite == true)
}

@Test
func promotionRejectsNoteAfterSingleRecallWithoutCanary() {
    let proposal = BrokerMemoryInsights.proposePromotion(
        content: "Scratch reminder about MiniLM cache warmup before the first recall.",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
        ],
        sessionID: UUID(),
        sourceFrameID: 2,
        scope: nil,
        longTermDocuments: [],
        recallSignals: BrokerSessionRecallSignals(
            recallCount: 1,
            uniqueQueryCount: 1,
            lastRetrievedAtMs: 1,
            averageScore: 0.9
        )
    )
    #expect(proposal.shouldWrite == false)
    #expect(proposal.reasons.contains { $0.contains("requires >=2 recalls") })
}

@Test
func promotionWritesNoteAfterTwoRecallsAndHighScore() {
    let proposal = BrokerMemoryInsights.proposePromotion(
        content: "Scratch reminder about MiniLM cache warmup before the first recall.",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.note.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
        ],
        sessionID: UUID(),
        sourceFrameID: 3,
        scope: nil,
        longTermDocuments: [],
        recallSignals: BrokerSessionRecallSignals(
            recallCount: 2,
            uniqueQueryCount: 2,
            lastRetrievedAtMs: 1,
            averageScore: 0.9
        )
    )
    #expect(proposal.shouldWrite == true)
}

@Test
func promotionStillWritesDecisionContainingDoNotWrite() {
    let proposal = BrokerMemoryInsights.proposePromotion(
        content: "Decision: keep MiniLM as the default embedder and do not write embeddings to disk.",
        metadata: [
            MemoryMetadataKeys.type: MemoryType.decision.rawValue,
            MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
        ],
        sessionID: UUID(),
        sourceFrameID: 4,
        scope: nil,
        longTermDocuments: []
    )
    #expect(proposal.shouldWrite == true)
}
