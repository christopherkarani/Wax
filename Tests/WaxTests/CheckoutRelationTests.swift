import Foundation
import Testing
@testable import Wax

private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

struct CheckoutRelationTests {
    @Test(arguments: [
        (shaA, Optional(shaA), OnThisTree.yes),
        (String(shaA.prefix(12)), Optional(shaA), OnThisTree.yes),
        (shaA, Optional(shaB), OnThisTree.other),
        ("not-a-sha", Optional(shaA), OnThisTree.unknown),
        ("", Optional(shaA), OnThisTree.unknown),
        (shaA, Optional<String>.none, OnThisTree.unknown),
    ] as [(String, String?, OnThisTree)])
    func checkoutRelationsClassifiesWithoutGit(stored: String, live: String?, expected: OnThisTree) {
        let relations = MemorySemantics.checkoutRelations(
            storedSHAs: [stored],
            live: GitCheckoutSnapshot(sha: live),
            repoRootPath: nil
        )
        #expect(relations[stored] == expected)
    }

    @Test
    func checkoutRelationsKeepsOneEntryPerStoredSHA() {
        let relations = MemorySemantics.checkoutRelations(
            storedSHAs: [shaA, shaA, shaB],
            live: GitCheckoutSnapshot(sha: shaB),
            repoRootPath: nil
        )
        #expect(relations.count == 2)
        #expect(relations[shaA] == .other)
        #expect(relations[shaB] == .yes)
    }

    @Test
    func mergeHitsStampsOtherWhenRelationMapIsEmpty() {
        let live = GitCheckoutSnapshot(sha: shaB, branch: "main", worktree: nil)
        let hits = (1...3).map { index in
            relationHit(
                frameID: UInt64(index),
                text: "distinct lane \(index) ExtraToken\(index)",
                sha: shaA
            )
        }
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: hits,
            limit: 5,
            nowMs: 1,
            query: "distinct lane",
            liveCheckout: live,
            relations: [:]
        )
        #expect(merged.count == 3)
        #expect(merged.allSatisfy {
            $0.metadata[MemoryMetadataKeys.onThisTree] == OnThisTree.other.rawValue
        })
    }

    @Test
    func mergeHitsStampsAncestorFromRelationMap() {
        let hit = relationHit(
            frameID: 1,
            text: "ancestor checkout row",
            sha: shaA
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [hit],
            limit: 5,
            nowMs: 1,
            query: "ancestor",
            liveCheckout: GitCheckoutSnapshot(sha: shaB),
            relations: [shaA: .ancestor]
        )
        let stamped = merged.first
        #expect(stamped?.metadata[MemoryMetadataKeys.onThisTree] == OnThisTree.ancestor.rawValue)
    }

    @Test
    func rankingAdjustedScoreTrustsStampedYesOverMismatchedLiveSHA() {
        let stamped = landedClaim(frameID: 1, sha: shaA, tree: .yes)
        let score = LayeredRecall.rankingAdjustedScore(
            stamped,
            nowMs: 1,
            query: "GitLiveProbe",
            liveCheckout: GitCheckoutSnapshot(sha: shaB)
        )
        #expect(abs(score - 0.90) < 0.0001)
    }

    @Test
    func rankingAdjustedScoreDemotesUnstampedLandedClaimOnOtherSHA() {
        let unstamped = landedClaim(frameID: 2, sha: shaA, tree: nil)
        let score = LayeredRecall.rankingAdjustedScore(
            unstamped,
            nowMs: 1,
            query: "GitLiveProbe",
            liveCheckout: GitCheckoutSnapshot(sha: shaB)
        )
        #expect(abs(score - 0.65) < 0.0001)
    }

    @Test
    func ancestorRelationStillDemotesUnlandedSkipList() throws {
        let execute = relationHit(
            frameID: 1,
            score: 0.70,
            text: "C01 GitLiveProbe Strong execute on this checkout.",
            sha: shaA,
            checkoutStatus: .intent
        )
        let skip = relationHit(
            frameID: 2,
            score: 0.99,
            text: "Do not re-run C01 GitLiveProbe / C02 UniqueRanking / C03 CompactSummary this session.",
            sha: shaA
        )
        let merged = LayeredRecall.mergeHits(
            sessionHits: [],
            durableHits: [execute, skip],
            limit: 5,
            nowMs: 0,
            query: "GitLiveProbe",
            liveCheckout: GitCheckoutSnapshot(sha: shaB),
            relations: [shaA: .ancestor]
        )
        let texts = merged.map(\.text)
        let executeAt = try #require(texts.firstIndex { $0.contains("Strong execute") })
        let skipAt = try #require(texts.firstIndex { $0.contains("Do not re-run") })
        #expect(executeAt < skipAt)
        #expect(merged[executeAt].metadata[MemoryMetadataKeys.onThisTree] == OnThisTree.ancestor.rawValue)
        #expect(merged[skipAt].metadata[MemoryMetadataKeys.onThisTree] == OnThisTree.ancestor.rawValue)
        #expect(merged[skipAt].flags.contains(.unlandedDemoted))
        #expect(abs(merged[executeAt].score - 0.70) < 0.0001)
    }
}

private func relationHit(
    frameID: UInt64,
    score: Float = 0.90,
    text: String,
    sha: String,
    checkoutStatus: MemoryCheckoutStatus? = nil
) -> LayeredRecall.Hit {
    var metadata = [MemoryMetadataKeys.gitSHA: sha]
    if let checkoutStatus {
        metadata[MemoryMetadataKeys.checkoutStatus] = checkoutStatus.rawValue
    }
    return LayeredRecall.Hit(
        id: .durable(frameID: frameID),
        score: score,
        text: text,
        preview: text,
        metadata: metadata,
        explanations: [],
        timestampMs: 0
    )
}

private func landedClaim(
    frameID: UInt64,
    sha: String,
    tree: OnThisTree?
) -> LayeredRecall.Hit {
    var metadata = [
        MemoryMetadataKeys.checkoutStatus: MemoryCheckoutStatus.landed.rawValue,
        MemoryMetadataKeys.gitSHA: sha,
    ]
    if let tree {
        metadata[MemoryMetadataKeys.onThisTree] = tree.rawValue
    }
    return LayeredRecall.Hit(
        id: .durable(frameID: frameID),
        score: 0.90,
        text: "C01 GitLiveProbe Strong execute",
        preview: "C01 GitLiveProbe Strong execute",
        metadata: metadata,
        explanations: [],
        timestampMs: 0
    )
}
