import Foundation
import Testing
@testable import Wax
import WaxTestSupport
import WaxCore

// MARK: - Expired hits must not shrink the result set below topK

@Test
func searchFillsTopKWhenExpiredHitsOutrankValidOnes() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))

        var expiredIDs: Set<UInt64> = []
        for index in 0..<2 {
            let body = "orchid orchid orchid orchid orchid expired reminder \(index)"
            let id = try await wax.put(
                Data(body.utf8),
                options: FrameMetaSubset(
                    searchText: body,
                    metadata: Metadata([MemoryMetadataKeys.expiresAtMs: "1"])
                )
            )
            try await text.indexText(frameId: id, text: body)
            expiredIDs.insert(id)
        }
        for index in 0..<4 {
            let body = "orchid care note \(index) with unrelated filler words"
            let id = try await wax.put(Data(body.utf8), options: FrameMetaSubset(searchText: body))
            try await text.indexText(frameId: id, text: body)
        }
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(query: "orchid", lane: .textOnly, topK: 3)
        )

        #expect(response.results.count == 3)
        #expect(response.results.allSatisfy { !expiredIDs.contains($0.frameId) })

        try await wax.close()
    }
}

// MARK: - Query-derived time ranges must not hide future-looking questions

@Test
func futureLookingTemporalQueriesStillReturnMatchingMemories() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
        try await memory.save("Dentist appointment is planned for tomorrow morning")
        try await memory.save("Team offsite is planned for next week in Lisbon")

        let tomorrow = try await memory.search(
            "what is planned for tomorrow",
            options: .init(mode: .textOnly)
        )
        #expect(tomorrow.items.contains { $0.text.contains("Dentist") })

        let nextWeek = try await memory.search(
            "what is planned for next week",
            options: .init(mode: .textOnly)
        )
        #expect(nextWeek.items.contains { $0.text.contains("offsite") })

        try await memory.close()
    }
}

// MARK: - Token truncation must not end in a replacement character

@Test
func tokenTruncationNeverEndsWithReplacementCharacter() async throws {
    let counter = try await TokenCounter.shared()
    let text = "日本語のテキストを途中で切る 🎉 emoji ünïcödé naïve café 中文字符测试"
    let total = await counter.count(text)
    #expect(total > 4)
    for maxTokens in 1..<total {
        let truncated = await counter.truncate(text, maxTokens: maxTokens)
        #expect(!truncated.hasSuffix("\u{FFFD}"), "maxTokens=\(maxTokens) produced \(truncated)")
    }
}

// MARK: - Attach must not clobber a concurrent text-only write

@Test
func attachDuringConcurrentTextOnlyRememberReportsDegraded() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.requireOnDeviceProviders = false
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: nil,
            initialEmbeddingStatus: .loading
        )
        // Runs after attach's (empty-store) coverage scan, while attach is
        // suspended and before it writes the lifecycle: a deterministic interleave.
        await orchestrator.setCoverageScanHookForTesting {
            do {
                _ = try await orchestrator.remember("saved without a vector while attach was suspended")
            } catch {
                Issue.record("text-only remember during attach failed: \(error)")
            }
        }
        await orchestrator.attachEmbedder(DeterministicTextEmbedder())

        let status = await orchestrator.runtimeStats().embeddingStatus
        guard case .degraded = status else {
            Issue.record("expected degraded after concurrent text-only remember, got \(status)")
            try await orchestrator.close()
            return
        }
        try await orchestrator.close()
    }
}

// MARK: - Inferred time range: reported, past-only, and opt-out

@Test
func inferredIngestRangeSkipsFutureWindowsAndKeepsPastOnes() {
    let anchorMs: Int64 = 1_740_000_000_000
    #expect(MemoryOrchestrator.pastIngestTimeRange(inferredFrom: "what is planned for tomorrow", anchorMs: anchorMs) == nil)
    #expect(MemoryOrchestrator.pastIngestTimeRange(inferredFrom: "offsite next week", anchorMs: anchorMs) == nil)
    let lastWeek = MemoryOrchestrator.pastIngestTimeRange(inferredFrom: "project recap last week", anchorMs: anchorMs)
    #expect(lastWeek != nil)
    #expect((lastWeek?.after ?? .max) < anchorMs)
}

@Test
func lastWeekRecallReportsInferredRangeAndCanBeDisabled() async throws {
    try await TempFiles.withTempFile { url in
        let anchorMs: Int64 = 1_740_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000
        let wax = try await Wax.create(at: url)
        let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
        let olderText = "project recap timeline details from two weeks ago"
        let olderID = try await wax.put(
            Data(olderText.utf8),
            options: FrameMetaSubset(searchText: olderText),
            timestampMs: anchorMs - 14 * dayMs
        )
        try await text.indexText(frameId: olderID, text: olderText)
        let recentText = "project recap timeline details from earlier this week"
        let recentID = try await wax.put(
            Data(recentText.utf8),
            options: FrameMetaSubset(searchText: recentText),
            timestampMs: anchorMs - 5 * dayMs
        )
        try await text.indexText(frameId: recentID, text: recentText)
        try await text.commit()
        try await wax.commit()
        try await wax.close()

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
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

        let filtered = try await orchestrator.recallExecution(query: "project recap last week").context
        let filteredIDs = Set(filtered.items.map(\.frameId))
        #expect(filteredIDs.contains(recentID))
        #expect(!filteredIDs.contains(olderID))
        let inferred = filtered.diagnostics?.inferredTimeRange
        #expect(inferred != nil)
        #expect((inferred?.afterMs ?? .max) < anchorMs)

        let unfiltered = try await orchestrator.recallExecution(
            query: "project recap last week",
            inferTimeRange: false
        ).context
        let unfilteredIDs = Set(unfiltered.items.map(\.frameId))
        #expect(unfilteredIDs.contains(recentID))
        #expect(unfilteredIDs.contains(olderID))
        #expect(unfiltered.diagnostics?.inferredTimeRange == nil)

        try await orchestrator.close()
    }
}

// MARK: - Public context budget

@Test
func maxContextTokensLetsLargeTopKReturnEveryHit() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
        // ~150 tokens each: 20 hits cannot fit the default 1,500-token budget.
        let body = """
            measured ablation stakes along the eastern transect, recorded snow depth at each \
            probe site, sampled surface albedo with the handheld radiometer, logged meltwater \
            discharge at the outlet gauge twice daily, mapped crevasse positions near the upper \
            camp with the differential receiver, photographed moraine boundaries for the repeat \
            survey archive, checked the automatic weather station battery and anemometer, noted \
            debris cover changes on the lower tongue, and filed the field notes with the team \
            lead before the evening radio call with base camp
            """
        for index in 0..<20 {
            try await memory.save("Glacier survey log \(index): \(body) (entry \(index)).")
        }

        let defaultBudget = try await memory.search("glacier survey") { options in
            options.topK = 20
            options.mode = .textOnly
        }
        #expect(defaultBudget.items.count < 20)

        let wide = try await memory.search("glacier survey") { options in
            options.topK = 20
            options.mode = .textOnly
            options.maxContextTokens = 16_000
        }
        #expect(wide.items.count == 20)

        let clamped = try await memory.search("glacier survey") { options in
            options.topK = 20
            options.mode = .textOnly
            options.maxContextTokens = 1
        }
        #expect(clamped.totalTokens <= Memory.SearchOptions.maxContextTokensRange.lowerBound)
        #expect(!clamped.items.isEmpty)

        try await memory.close()
    }
}

// MARK: - save returns the frame ID

@Test
func saveReturnsFrameIDUsableForDelete() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
        let keepID = try await memory.save("Quartz sample stored in drawer A")
        let dropID = try await memory.save("Quartz sample stored in drawer B")
        #expect(keepID != dropID)
        let resavedID = try await memory.save("Quartz sample stored in drawer B")
        #expect(resavedID == dropID)

        try await memory.delete(frameID: dropID)
        let results = try await memory.search("quartz sample drawer", options: .init(mode: .textOnly))
        let ids = Set(results.items.map(\.frameId))
        #expect(ids.contains(keepID))
        #expect(!ids.contains(dropID))
        try await memory.close()
    }
}

// MARK: - Vector coverage must not swallow decode errors

@Test
func corruptVectorSegmentThrowsInsteadOfReportingNoVectors() {
    #expect(throws: (any Error).self) {
        _ = try MemoryOrchestrator.vecSegmentFrameIds(bytes: Data([0x01, 0x02, 0x03]))
    }
}

private struct CoverageReadFailure: Error {}

private func embeddedOrchestrator(
    at url: URL,
    initialStatus: EmbeddingStatus? = nil
) async throws -> MemoryOrchestrator {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.requireOnDeviceProviders = false
    if let initialStatus {
        return try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: nil,
            initialEmbeddingStatus: initialStatus
        )
    }
    return try await MemoryOrchestrator(at: url, config: config, embedder: DeterministicTextEmbedder())
}

@Test
func unreadableCoverageMarksStatsDegraded() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url)
        await orchestrator.setCoverageReadFailureForTesting(CoverageReadFailure())

        let stats = await orchestrator.runtimeStats()
        #expect(stats.framesWithoutVectors == 0)
        guard case .degraded(_, let reason) = stats.embeddingStatus else {
            Issue.record("expected degraded when coverage is unreadable, got \(stats.embeddingStatus)")
            try await orchestrator.close()
            return
        }
        #expect(reason.contains("vector coverage unknown"))
        try await orchestrator.close()
    }
}

@Test
func backfillPropagatesUnreadableCoverage() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url)
        await orchestrator.setCoverageReadFailureForTesting(CoverageReadFailure())
        await #expect(throws: CoverageReadFailure.self) {
            _ = try await orchestrator.backfillUnembedded()
        }
        try await orchestrator.close()
    }
}

@Test
func committedCoverageCacheFollowsManifestChanges() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url)
        try await orchestrator.remember("first vector-backed note about basalt")
        try await orchestrator.flush()
        #expect(await orchestrator.runtimeStats().framesWithoutVectors == 0)

        // A second commit replaces the committed index; a stale cache would
        // report the new frame as missing a vector.
        try await orchestrator.remember("second vector-backed note about granite")
        try await orchestrator.flush()
        #expect(await orchestrator.runtimeStats().framesWithoutVectors == 0)
        try await orchestrator.close()
    }
}

@Test
func coverageUnknownClearsOnNextSuccessfulStats() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url)
        await orchestrator.setCoverageReadFailureForTesting(CoverageReadFailure())
        guard case .degraded = await orchestrator.runtimeStats().embeddingStatus else {
            Issue.record("expected degraded while coverage is unreadable")
            try await orchestrator.close()
            return
        }

        await orchestrator.setCoverageReadFailureForTesting(nil)
        let status = await orchestrator.runtimeStats().embeddingStatus
        guard case .active = status else {
            Issue.record("expected active once coverage reads again, got \(status)")
            try await orchestrator.close()
            return
        }
        try await orchestrator.close()
    }
}

@Test
func refreshDuringCoverageScanKeepsNewerAttachReason() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url)
        let newer = DeterministicTextEmbedder(
            identity: EmbeddingIdentity(provider: "Mock", model: "Newer", dimensions: 2, normalized: true)
        )
        // The refresh scan sees an empty store (fully embedded). While it is
        // suspended, a frame without a vector lands and a newer attach reports
        // it. The stale refresh result must not overwrite that.
        await orchestrator.setCoverageScanHookForTesting {
            await orchestrator.setCoverageScanHookForTesting(nil)
            do {
                var options = FrameMetaSubset()
                options.role = .document
                options.searchText = "frame saved without a vector"
                _ = try await orchestrator.wax.put(Data("frame saved without a vector".utf8), options: options)
                try await orchestrator.flush()
            } catch {
                Issue.record("could not write the unembedded frame: \(error)")
            }
            await orchestrator.attachEmbedder(newer)
        }
        _ = try await orchestrator.backfillUnembedded()

        let status = await orchestrator.runtimeStats().embeddingStatus
        #expect(status.identity?.model == "Newer")
        guard case .degraded = status else {
            Issue.record("expected the newer attach's degraded reason to survive, got \(status)")
            try await orchestrator.close()
            return
        }
        try await orchestrator.close()
    }
}

@Test
func refreshDuringCoverageScanDoesNotResurrectUnavailableEmbedder() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url)
        await orchestrator.setCoverageScanHookForTesting {
            await orchestrator.setCoverageScanHookForTesting(nil)
            await orchestrator.markUnavailable("provider crashed during refresh")
        }
        // Empty store: backfill finds nothing missing and refreshes coverage.
        _ = try await orchestrator.backfillUnembedded()

        let status = await orchestrator.runtimeStats().embeddingStatus
        guard case .unavailable = status else {
            Issue.record("expected unavailable to survive the refresh, got \(status)")
            try await orchestrator.close()
            return
        }
        try await orchestrator.close()
    }
}

@Test
func attachDuringScanDoesNotOverrideMarkUnavailable() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url, initialStatus: .loading)
        await orchestrator.setCoverageScanHookForTesting {
            await orchestrator.setCoverageScanHookForTesting(nil)
            await orchestrator.markUnavailable("load timed out")
        }
        await orchestrator.attachEmbedder(DeterministicTextEmbedder())

        let status = await orchestrator.runtimeStats().embeddingStatus
        guard case .unavailable = status else {
            Issue.record("expected unavailable to win over a suspended attach, got \(status)")
            try await orchestrator.close()
            return
        }
        try await orchestrator.close()
    }
}

@Test
func attachDuringScanDoesNotOverrideNewerAttach() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await embeddedOrchestrator(at: url, initialStatus: .loading)
        let newer = DeterministicTextEmbedder(
            identity: EmbeddingIdentity(provider: "Mock", model: "Newer", dimensions: 2, normalized: true)
        )
        await orchestrator.setCoverageScanHookForTesting {
            await orchestrator.setCoverageScanHookForTesting(nil)
            await orchestrator.attachEmbedder(newer)
        }
        await orchestrator.attachEmbedder(DeterministicTextEmbedder())

        let identity = await orchestrator.runtimeStats().embeddingStatus.identity
        #expect(identity?.model == "Newer")
        try await orchestrator.close()
    }
}

// MARK: - delete(frameID:) must remove every chunk of a long save

@Test
func deletingLongSaveRemovesItsChunksFromSearch() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
        let filler = String(
            repeating: "The survey crew logged stake heights, snow depth and meltwater flow at camp. ",
            count: 60
        )
        let longID = try await memory.save("Zirconium sample notes. " + filler)
        let keepID = try await memory.save("Zirconium reference card kept in drawer C")

        let before = try await memory.search("zirconium", options: .init(mode: .textOnly))
        #expect(before.items.count >= 2)

        try await memory.delete(frameID: longID)
        let after = try await memory.search("zirconium", options: .init(mode: .textOnly))
        let remaining = Set(after.items.map(\.frameId))
        #expect(remaining == [keepID])
        let crewHits = try await memory.search("meltwater stake heights", options: .init(mode: .textOnly))
        #expect(crewHits.items.isEmpty)
        try await memory.close()
    }
}
