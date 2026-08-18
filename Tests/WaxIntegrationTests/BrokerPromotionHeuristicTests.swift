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
