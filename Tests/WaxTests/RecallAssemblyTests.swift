import Foundation
import Testing
@testable import Wax

@Suite("Recall assembly")
struct RecallAssemblyTests {
    @Test
    func packSkipsHitsThatExceedBudgetThenContinues() async {
        let oversized = payload(
            frameId: 1,
            score: 0.9,
            expansionText: String(repeating: "x", count: 80)
        )
        let small = payload(
            frameId: 2,
            score: 0.8,
            expansionText: "ok"
        )
        var config = FastRAGConfig(
            maxContextTokens: 50,
            expansionMaxTokens: 80,
            snippetMaxTokens: 0,
            maxSnippets: 0
        )
        config.maxSurrogates = 0

        let packed = await RecallAssembly.pack(
            query: "q",
            payloads: [oversized, small],
            config: config,
            tokenizer: .character,
            nowMs: nil
        )

        #expect(packed.items.map(\.frameId) == [2])
        #expect(packed.items.map(\.kind) == [.expanded])
        #expect(packed.items.first?.text == "ok")
        #expect(packed.totalTokens <= 50)
        #expect(packed.totalTokens == 2)
        #expect(!packed.items.contains { $0.text.contains(String(repeating: "x", count: 80)) })
    }

    @Test
    func packTakesAtMostOneExpansionAndDoesNotAlsoEmitItAsSnippet() async {
        let first = payload(
            frameId: 1,
            score: 0.9,
            expansionText: "expanded-one",
            snippetText: "snippet-one"
        )
        let second = payload(
            frameId: 2,
            score: 0.8,
            expansionText: "expanded-two",
            snippetText: "snippet-two"
        )
        let config = FastRAGConfig(
            maxContextTokens: 10_000,
            expansionMaxTokens: 200,
            snippetMaxTokens: 200,
            maxSnippets: 8
        )

        let packed = await RecallAssembly.pack(
            query: "q",
            payloads: [first, second],
            config: config,
            tokenizer: .character,
            nowMs: nil
        )

        #expect(packed.items.filter { $0.kind == .expanded }.count == 1)
        #expect(packed.items.first?.kind == .expanded)
        #expect(packed.items.first?.frameId == 1)
        #expect(packed.items.first?.text == "expanded-one")
        #expect(packed.items.contains { $0.kind == .snippet && $0.frameId == 2 })
        #expect(!packed.items.contains { $0.kind == .snippet && $0.frameId == 1 })
        #expect(!packed.items.contains { $0.kind == .expanded && $0.frameId == 2 })
    }

    @Test
    func packEmptyPayloadsYieldEmptyItemsAndZeroTokens() async {
        let packed = await RecallAssembly.pack(
            query: "q",
            payloads: [],
            config: FastRAGConfig(maxContextTokens: 128),
            tokenizer: .character,
            nowMs: nil
        )

        #expect(packed.query == "q")
        #expect(packed.items.isEmpty)
        #expect(packed.totalTokens == 0)
    }

    @Test
    func packDoesNotRewritePublishedRankingScore() async {
        let hit = payload(
            frameId: 7,
            score: 0.37,
            expansionText: "keep-score"
        )
        let packed = await RecallAssembly.pack(
            query: "q",
            payloads: [hit],
            config: FastRAGConfig(maxContextTokens: 1_000, expansionMaxTokens: 200),
            tokenizer: .character,
            nowMs: nil
        )

        #expect(packed.items.map(\.score) == [0.37])
    }

    @Test
    func packAttachesAccessReasonsAtNowMsWithoutDuplicating() async {
        let nowMs: Int64 = 1_700_000_000_000
        var stats = FrameAccessStats(frameId: 3, nowMs: nowMs - 60_000)
        stats.engagementCount = 1
        stats.lastEngagementMs = nowMs - 60_000
        let hit = payload(
            frameId: 3,
            score: 1.0,
            expansionText: "used recently",
            explanations: ["keyword match", "recently used"],
            accessStats: stats
        )

        let packed = await RecallAssembly.pack(
            query: "q",
            payloads: [hit],
            config: FastRAGConfig(maxContextTokens: 1_000, expansionMaxTokens: 200),
            tokenizer: .character,
            nowMs: nowMs
        )

        #expect(packed.items.first?.explanations == ["keyword match", "recently used"])
    }

    @Test
    func recallAssemblyIsNotNamedInPublicAPIDocs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let publicAPI = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Resources/skills/public/wax/references/public-api.md"
            ),
            encoding: .utf8
        )
        #expect(!publicAPI.contains("RecallAssembly"))
    }

    private func payload(
        frameId: UInt64,
        score: Float,
        expansionText: String? = nil,
        snippetText: String = "",
        explanations: [String] = ["keyword match"],
        accessStats: FrameAccessStats? = nil
    ) -> RecallAssembly.Payload {
        RecallAssembly.Payload(
            hit: SearchResponse.Result(
                frameId: frameId,
                score: score,
                previewText: snippetText.isEmpty ? expansionText : snippetText,
                sources: [.text],
                explanations: explanations
            ),
            expansionText: expansionText,
            snippetText: snippetText,
            accessStats: accessStats
        )
    }
}
