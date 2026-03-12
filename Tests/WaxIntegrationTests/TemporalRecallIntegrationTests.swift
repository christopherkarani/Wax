import Foundation
import Testing
import Wax

private func makeTemporalRecallStore(
    at url: URL,
    olderTimestampMs: Int64,
    recentTimestampMs: Int64
) async throws -> (olderFrameId: UInt64, recentFrameId: UInt64) {
    let wax = try await Wax.create(at: url)
    let textSearch = try await wax.enableTextSearch()

    let olderText = "project recap timeline details from two weeks ago"
    let recentText = "project recap timeline details from earlier this week"

    let olderFrameId = try await wax.put(
        Data(olderText.utf8),
        options: FrameMetaSubset(searchText: olderText),
        timestampMs: olderTimestampMs
    )
    let recentFrameId = try await wax.put(
        Data(recentText.utf8),
        options: FrameMetaSubset(searchText: recentText),
        timestampMs: recentTimestampMs
    )

    try await textSearch.index(frameId: olderFrameId, text: olderText)
    try await textSearch.index(frameId: recentFrameId, text: recentText)
    try await textSearch.commit()

    try await wax.commit()
    try await wax.close()
    return (olderFrameId, recentFrameId)
}

@Test
func recallQueryWithLastWeekFiltersToRecentFrames() async throws {
    try await TempFiles.withTempFile { url in
        let anchorMs: Int64 = 1_740_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000
        let older = anchorMs - (14 * dayMs)
        let recent = anchorMs - (5 * dayMs)
        let ids = try await makeTemporalRecallStore(at: url, olderTimestampMs: older, recentTimestampMs: recent)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.rag = FastRAGConfig(
            maxContextTokens: 128,
            expansionMaxTokens: 48,
            snippetMaxTokens: 24,
            maxSnippets: 6,
            searchTopK: 10,
            searchMode: .textOnly,
            deterministicNowMs: anchorMs
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let context = try await orchestrator.recall(query: "project recap last week")

        #expect(!context.items.isEmpty)
        let frameIds = Set(context.items.map(\.frameId))
        #expect(frameIds.contains(ids.recentFrameId))
        #expect(!frameIds.contains(ids.olderFrameId))

        try await orchestrator.close()
    }
}

@Test
func nonTemporalQueryStillReturnsOlderAndRecentCandidates() async throws {
    try await TempFiles.withTempFile { url in
        let anchorMs: Int64 = 1_740_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000
        let older = anchorMs - (14 * dayMs)
        let recent = anchorMs - (5 * dayMs)
        let ids = try await makeTemporalRecallStore(at: url, olderTimestampMs: older, recentTimestampMs: recent)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.rag = FastRAGConfig(
            maxContextTokens: 256,
            expansionMaxTokens: 0,
            snippetMaxTokens: 64,
            maxSnippets: 10,
            searchTopK: 10,
            searchMode: .textOnly,
            deterministicNowMs: anchorMs
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let context = try await orchestrator.recall(query: "project recap timeline")

        #expect(!context.items.isEmpty)
        let frameIds = Set(context.items.map(\.frameId))
        #expect(frameIds.contains(ids.recentFrameId))
        #expect(frameIds.contains(ids.olderFrameId))

        try await orchestrator.close()
    }
}

@Test
func temporalLookingWordsDoNotAccidentallyFilterRecall() async throws {
    try await TempFiles.withTempFile { url in
        let anchorMs: Int64 = 1_740_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000
        let older = anchorMs - (14 * dayMs)
        let recent = anchorMs - (5 * dayMs)
        let ids = try await makeTemporalRecallStore(at: url, olderTimestampMs: older, recentTimestampMs: recent)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.rag = FastRAGConfig(
            maxContextTokens: 256,
            expansionMaxTokens: 0,
            snippetMaxTokens: 64,
            maxSnippets: 10,
            searchTopK: 10,
            searchMode: .textOnly,
            deterministicNowMs: anchorMs
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let context = try await orchestrator.recall(query: "project recap timeline architecture")

        #expect(!context.items.isEmpty)
        let frameIds = Set(context.items.map(\.frameId))
        #expect(frameIds.contains(ids.recentFrameId))
        #expect(frameIds.contains(ids.olderFrameId))

        try await orchestrator.close()
    }
}
