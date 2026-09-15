import Foundation
import Testing
@testable import Wax

/// Remaining-holes paraphrases share C01/C02/C03 + PascalCase names and stay
/// under the 0.88 write Jaccard so identifier overlap / recall clustering
/// have to do the work.
private let holesA =
    "Remaining holes: C01 GitLiveProbe, C02 UniqueRanking, C03 CompactSummary. Do not re-propose."
private let holesB =
    "Still open on this tree: GitLiveProbe (C01), UniqueRanking (C02), CompactSummary (C03) — skip if already listed."
private let holesC =
    "Skip list for remaining work: C01 GitLiveProbe not landed; C02 UniqueRanking collapse; C03 CompactSummary field."
private let holesD =
    "Do not re-run C01 GitLiveProbe / C02 UniqueRanking / C03 CompactSummary this session."
private let sessionScorecard =
    "69/100 for this session; would use it again"

@Suite("UniqueRecallTests")
struct UniqueRecallTests {
    @Test
    func extractsPascalCaseIssueSHAAndTicketIdentifiers() {
        let ids = MemorySemantics.extractIdentifiers(
            "C01 GitLiveProbe on #211 at 466c1e6; T1 UniqueRanking"
        )
        #expect(ids.contains("c01"))
        #expect(ids.contains("gitliveprobe"))
        #expect(ids.contains("#211"))
        #expect(ids.contains("466c1e6"))
        #expect(ids.contains("t1"))
        #expect(ids.contains("uniqueranking"))
        #expect(!ids.contains("on"))
        #expect(!ids.contains("at"))
    }

    @Test
    func remainingHolesParaphrasesShareIdentifiersBelowTextJaccard() {
        #expect(MemorySemantics.similarity(lhs: holesA, rhs: holesB) < 0.88)
        #expect(MemorySemantics.identifiersMatch(holesA, holesB))
        #expect(MemorySemantics.identifiersMatch(holesA, holesC))
        #expect(MemorySemantics.identifiersMatch(holesA, holesD))
    }

    @Test
    func oneSharedIdentifierDoesNotMatchWhenJaccardIsLow() {
        let left = "C01 GitLiveProbe UniqueRanking CompactSummary ExtraTokenAlpha ExtraTokenBeta ExtraTokenGamma"
        let right = "C01 mentioned among UnrelatedTopic OtherSubject DifferentMatter"
        #expect(MemorySemantics.identifiersMatch(left, right) == false)
    }

    @Test
    func threeSharedIdentifiersMatchEvenWhenJaccardIsLow() {
        let left = "C01 C02 C03 ExtraOne ExtraTwo ExtraThree ExtraFour ExtraFive"
        let right = "C01 C02 C03 OtherOne OtherTwo OtherThree OtherFour OtherFive OtherSix OtherSeven"
        let overlap = MemorySemantics.identifierOverlap(lhs: left, rhs: right)
        #expect(overlap.shared >= 3)
        #expect(overlap.jaccard < 0.5)
        #expect(MemorySemantics.identifiersMatch(left, right))
    }

    @Test
    func mergeHitsCollapsesRemainingHolesParaphrasesAndDropsScorecard() {
        let nowMs: Int64 = 0
        let holes = [holesA, holesB, holesC, holesD].enumerated().map { index, text in
            uniqueHit(
                frameID: UInt64(index + 1),
                score: 0.90 - Float(index) * 0.01,
                text: text,
                horizon: .durable,
                metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
                timestampMs: Int64((index + 1) * 1_000)
            )
        }
        let rating = uniqueHit(
            frameID: 99,
            score: 0.88,
            text: sessionScorecard,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: 5_000
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: holes + [rating],
            limit: 5,
            nowMs: nowMs,
            query: "remaining holes GitLiveProbe"
        )
        #expect(merged.count == 1)
        #expect(merged.contains { $0.text.contains("/100") } == false)
        #expect(merged.contains { $0.text.contains("GitLiveProbe") })
        #expect(merged.first?.collapsedCount == 4)
        #expect(LayeredRecall.collapsedTotal(in: merged) == 3)
    }

    @Test
    func mergeHitsKeepsScorecardWhenQueryAsksForRating() {
        let holes = uniqueHit(
            frameID: 1,
            score: 0.91,
            text: holesA,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.constraint.rawValue]
        )
        let rating = uniqueHit(
            frameID: 2,
            score: 0.90,
            text: sessionScorecard,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue]
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [holes, rating],
            limit: 5,
            nowMs: 0,
            query: "session rating"
        )
        #expect(merged.contains { $0.text.contains("/100") })
        #expect(merged.contains { $0.text.contains("GitLiveProbe") })
    }

    @Test
    func mergeHitsPrefersStandingTypeOverNewerNoteInACluster() {
        let note = uniqueHit(
            frameID: 2,
            score: 0.95,
            text: holesB,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: 2_000
        )
        let constraint = uniqueHit(
            frameID: 1,
            score: 0.70,
            text: holesA,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.constraint.rawValue],
            timestampMs: 1_000
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [note, constraint],
            limit: 5,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.count == 1)
        #expect(merged.first?.frameID == 1)
        #expect(merged.first?.metadata[MemoryMetadataKeys.type] == MemoryType.constraint.rawValue)
    }

    @Test
    func mergeHitsDoesNotReserveACollapsedTwin() {
        let session = (1...5).map { index in
            uniqueHit(
                frameID: UInt64(index),
                score: 1.0 - Float(index) * 0.01,
                text: index == 1 ? holesA : "session unique lane \(index) AlphaToken\(index)",
                horizon: .working
            )
        }
        let durableTwin = uniqueHit(
            frameID: 50,
            score: 0.20,
            text: holesB,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue]
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: session,
            durableHits: [durableTwin],
            limit: 5,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.count == 5)
        let gitLive = merged.filter { $0.text.contains("GitLiveProbe") }
        #expect(gitLive.count == 1)
        #expect(merged.contains { $0.text == holesB } == false)
    }

    @Test
    func mergeHitsDoesNotReserveAScorecardForTheDurableHorizon() {
        let session = (1...5).map { index in
            uniqueHit(
                frameID: UInt64(index),
                score: 1.0 - Float(index) * 0.01,
                text: "session unique lane \(index) AlphaToken\(index)",
                horizon: .working
            )
        }
        let rating = uniqueHit(
            frameID: 99,
            score: 0.05,
            text: sessionScorecard,
            horizon: .durable
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: session,
            durableHits: [rating],
            limit: 5,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.count == 5)
        #expect(merged.contains { $0.text.contains("/100") } == false)
        #expect(merged.contains { $0.explanations.contains("current session") })
    }

    @Test
    func mergeHitsReservesDurableClusterWinnerNotARawParaphrase() throws {
        let session = (1...5).map { index in
            uniqueHit(
                frameID: UInt64(index),
                score: 1.0 - Float(index) * 0.01,
                text: "session unique lane \(index) AlphaToken\(index)",
                horizon: .working
            )
        }
        let constraint = uniqueHit(
            frameID: 10,
            score: 0.10,
            text: holesA,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.constraint.rawValue],
            timestampMs: 100
        )
        let louderNote = uniqueHit(
            frameID: 11,
            score: 0.30,
            text: holesB,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: 300
        )
        let otherNote = uniqueHit(
            frameID: 12,
            score: 0.20,
            text: holesC,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue],
            timestampMs: 200
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: session,
            durableHits: [constraint, louderNote, otherNote],
            limit: 5,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.count == 5)
        let reserved = try #require(merged.first { $0.text.contains("GitLiveProbe") })
        #expect(reserved.frameID == 10)
        #expect(reserved.collapsedCount == 3)
        #expect(reserved.metadata[MemoryMetadataKeys.type] == MemoryType.constraint.rawValue)
    }

    @Test
    func mergeHitsKeepsLockedIdenticalTextBesideUnlockedTwin() {
        let locked = uniqueHit(
            frameID: 1,
            score: 0.90,
            text: holesA,
            horizon: .durable,
            metadata: [
                MemoryMetadataKeys.type: MemoryType.constraint.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
            ]
        )
        let unlocked = uniqueHit(
            frameID: 2,
            score: 0.91,
            text: holesA,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.constraint.rawValue]
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [locked, unlocked],
            limit: 5,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.contains { $0.frameID == 1 })
        #expect(merged.contains { $0.frameID == 2 })
    }

    @Test
    func mergeHitsDoesNotDropStandingTextThatOnlySaysForThisSession() {
        let constraint = uniqueHit(
            frameID: 1,
            score: 0.92,
            text: "Pass cwd for this session when the host has no roots.",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.constraint.rawValue]
        )
        let fact = uniqueHit(
            frameID: 2,
            score: 0.80,
            text: "Mac desktop window lives in private rv-app.",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.fact.rawValue]
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [constraint, fact],
            limit: 2,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.contains { $0.frameID == 1 })
        #expect(LayeredRecall.looksScorecard(constraint.text) == false)
    }

    @Test
    func mergeHitsClustersHighTextJaccardWithoutIdentifiers() {
        let original = uniqueHit(
            frameID: 1,
            score: 0.90,
            text: "Prefer project-scoped recall and never auto-widen an empty project lane.",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.decision.rawValue]
        )
        let similar = uniqueHit(
            frameID: 2,
            score: 0.89,
            text: "Prefer project-scoped recall and never auto-widen an empty project lane now.",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.decision.rawValue],
            timestampMs: 2_000
        )
        #expect(MemorySemantics.identifiersMatch(original.text, similar.text) == false)
        #expect(MemorySemantics.similarity(lhs: original.text, rhs: similar.text) >= 0.55)
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [original, similar],
            limit: 5,
            nowMs: 0,
            query: "project-scoped recall"
        )
        #expect(merged.count == 1)
        #expect(merged.first?.collapsedCount == 2)
        #expect(merged.first?.frameID == 2)
    }

    @Test
    func mergeHitsDoesNotCollapseALockedTwin() {
        let locked = uniqueHit(
            frameID: 1,
            score: 0.90,
            text: holesA,
            horizon: .durable,
            metadata: [
                MemoryMetadataKeys.type: MemoryType.constraint.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
            ]
        )
        let newer = uniqueHit(
            frameID: 2,
            score: 0.91,
            text: holesB,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.constraint.rawValue]
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [locked, newer],
            limit: 5,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.contains { $0.frameID == 1 })
        #expect(merged.contains { $0.frameID == 2 })
    }

    @Test
    func mergeHitsDoesNotTreatSkipListConstraintsAsScorecards() {
        let skip = uniqueHit(
            frameID: 1,
            score: 0.92,
            text: "Stale Wax frames (do not follow): leftover 69/100 for this session dump.",
            horizon: .durable,
            metadata: [
                MemoryMetadataKeys.type: MemoryType.constraint.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
            ]
        )
        let fact = uniqueHit(
            frameID: 2,
            score: 0.80,
            text: "Mac desktop window lives in private rv-app.",
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.fact.rawValue]
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [skip, fact],
            limit: 2,
            nowMs: 0,
            query: "remaining holes"
        )
        #expect(merged.contains { $0.frameID == 1 })
        #expect(merged.contains { $0.frameID == 2 })
    }

    @Test
    func rankingAdjustedScoreDemotesScorecardsUnlessQueryAsks() {
        let card = uniqueHit(
            frameID: 1,
            score: 0.90,
            text: sessionScorecard,
            horizon: .durable,
            metadata: [MemoryMetadataKeys.type: MemoryType.note.rawValue]
        )
        #expect(
            abs(
                LayeredRecall.rankingAdjustedScore(card, nowMs: 1, query: "remaining holes")
                    - (0.90 - LayeredRecall.scorecardRankPenalty)
            ) < 0.0001
        )
        #expect(
            abs(LayeredRecall.rankingAdjustedScore(card, nowMs: 1, query: "session rating") - 0.90) < 0.0001
        )
    }

    @Test
    func recallSummaryNumbersTypeShortSHAAndOnThisTree() {
        let hit = uniqueHit(
            frameID: 7,
            score: 0.9,
            text: holesA,
            horizon: .durable,
            metadata: [
                MemoryMetadataKeys.type: MemoryType.constraint.rawValue,
                MemoryMetadataKeys.gitSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                MemoryMetadataKeys.onThisTree: OnThisTree.other.rawValue,
            ]
        )
        let line = RecallPresent.summaryLine(index: 1, hit: hit)
        #expect(line.hasPrefix("1. [constraint]"))
        #expect(line.contains("aaaaaaa"))
        #expect(line.contains("other"))
        #expect(line.contains("GitLiveProbe"))
        #expect(RecallPresent.summary(for: [hit]) == line)
    }

    @Test
    func fourNotesPlusScorecardRecallShowsOneCluster() async throws {
        let project = "unique-recall-\(UUID().uuidString.prefix(8))"
        try await withUniqueRecallBroker { service in
            for text in [holesA, holesB, holesC, holesD] {
                let write = await service.handle(.init(
                    command: "remember",
                    arguments: [
                        "content": .string(text),
                        "memory_type": .string("note"),
                        "durability": .string("durable"),
                        "project": .string(project),
                        "repo": .string(project),
                    ]
                ))
                #expect(write.ok == true, "remember holes failed: \(write.error ?? "nil")")
            }
            let ratingWrite = await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string(
                        "69/100 for this session; remaining holes GitLiveProbe UniqueRanking CompactSummary would use it again"
                    ),
                    "memory_type": .string("note"),
                    "durability": .string("durable"),
                    "project": .string(project),
                    "repo": .string(project),
                ]
            ))
            #expect(ratingWrite.ok == true, "remember rating failed: \(ratingWrite.error ?? "nil")")

            let recall = await service.handle(.init(
                command: "recall",
                arguments: [
                    "query": .string("remaining holes GitLiveProbe UniqueRanking CompactSummary"),
                    "mode": .string("text"),
                    "scope": .string("project"),
                    "project": .string(project),
                    "repo": .string(project),
                    "limit": .int(5),
                ]
            ))
            #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
            let payload = try #require(recall.payload?.objectValue)
            let hits = payload["results"]?.arrayValue ?? []
            let texts = hits.compactMap { $0.objectValue?["text"]?.stringValue }
            #expect(texts.filter { $0.contains("GitLiveProbe") }.count == 1)
            #expect(texts.contains { $0.contains("/100") } == false)
            #expect((payload["collapsed"]?.intValue ?? 0) >= 3)
            let summary = try #require(payload["summary"]?.stringValue)
            #expect(summary.contains("[note]"))
            #expect(summary.contains("1."))
            #expect(hits.first?.objectValue?["collapsed_count"]?.intValue == 4)
        }
    }
}

private func uniqueHit(
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

private func withUniqueRecallBroker<T>(
    _ body: (AgentBrokerService) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-unique-recall-\(UUID().uuidString)", isDirectory: true)
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
