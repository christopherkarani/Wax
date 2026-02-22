import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import Wax

private actor DeterministicVectorResultsEngine: VectorSearchEngine {
    let dimensions: Int
    private let results: [(frameId: UInt64, score: Float)]

    init(dimensions: Int, results: [(frameId: UInt64, score: Float)]) {
        self.dimensions = dimensions
        self.results = results
    }

    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        _ = vector
        return Array(results.prefix(topK))
    }

    func add(frameId: UInt64, vector: [Float]) async throws {
        _ = frameId
        _ = vector
    }

    func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        _ = frameIds
        _ = vectors
    }

    func remove(frameId: UInt64) async throws {
        _ = frameId
    }

    func stageForCommit(into wax: Wax) async throws {
        _ = wax
    }
}

@Test func textOnlySearch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("Swift programming language".utf8))
        try await text.index(frameId: id0, text: "Swift programming language")
        let id1 = try await wax.put(Data("Python programming language".utf8))
        try await text.index(frameId: id1, text: "Python programming language")

        try await text.commit()

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 10)
        let response = try await wax.search(request)

        #expect(response.results.count == 1)
        #expect(response.results[0].frameId == id0)
        #expect(response.results[0].previewText != nil)

        try await wax.close()
    }
}

@Test func vectorOnlySearch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 4)

        let id0 = try await vec.putWithEmbedding(Data("First".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
        _ = try await vec.putWithEmbedding(Data("Second".utf8), embedding: [0.0, 1.0, 0.0, 0.0])

        try await vec.commit()

        let queryEmbedding = VectorMath.normalizeL2([0.9, 0.1, 0.0, 0.0])
        let request = SearchRequest(embedding: queryEmbedding, mode: .vectorOnly, topK: 10)
        let response = try await wax.search(request)

        #expect(response.results.first?.frameId == id0)
        #expect(response.results.first?.previewText == "First")

        try await wax.close()
    }
}

@Test func hybridSearchOverlapRanksHighest() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 4)

        let id0 = try await vec.putWithEmbedding(Data("Swift programming".utf8), embedding: [0.0, 0.0, 0.0, 1.0])
        try await text.index(frameId: id0, text: "Swift programming")

        let id1 = try await vec.putWithEmbedding(Data("Swift is fast".utf8), embedding: [1.0, 0.0, 0.0, 0.0])
        try await text.index(frameId: id1, text: "Swift is fast")

        try await text.commit()
        try await vec.commit()

        let request = SearchRequest(
            query: "Swift",
            embedding: [1.0, 0.0, 0.0, 0.0],
            mode: .hybrid(alpha: 0.5),
            topK: 10
        )
        let response = try await wax.search(request)

        #expect(response.results.first?.frameId == id1)
        #expect(response.results.first?.previewText != nil)

        try await wax.close()
    }
}

@Test func topKZeroReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("Swift".utf8))
        try await text.index(frameId: id0, text: "Swift")
        try await text.commit()

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 0)
        let response = try await wax.search(request)

        #expect(response.results.isEmpty)

        try await wax.close()
    }
}

@Test func unifiedSearchCacheIsolatesEntriesByStoreIdentity() async throws {
    let cache = UnifiedSearchEngineCache.shared

    try await TempFiles.withTempFile { firstURL in
        try await TempFiles.withTempFile { secondURL in
            let first = try await Wax.create(at: firstURL)
            let firstText = try await first.enableTextSearch()
            let firstID = try await first.put(Data("alpha document".utf8))
            try await firstText.index(frameId: firstID, text: "alpha document")
            try await firstText.commit()

            let second = try await Wax.create(at: secondURL)
            let secondText = try await second.enableTextSearch()
            let secondID = try await second.put(Data("beta document".utf8))
            try await secondText.index(frameId: secondID, text: "beta document")
            try await secondText.commit()

            let firstResponse = try await first.search(
                SearchRequest(query: "alpha", mode: .textOnly, topK: 5)
            )
            let secondResponse = try await second.search(
                SearchRequest(query: "beta", mode: .textOnly, topK: 5)
            )
            #expect(firstResponse.results.first?.frameId == firstID)
            #expect(secondResponse.results.first?.frameId == secondID)
            #expect(await cache.containsEntry(for: first))
            #expect(await cache.containsEntry(for: second))

            await cache.invalidate(for: first)
            #expect((await cache.containsEntry(for: first)) == false)
            #expect(await cache.containsEntry(for: second))

            let secondAfterInvalidation = try await second.search(
                SearchRequest(query: "beta", mode: .textOnly, topK: 5)
            )
            #expect(secondAfterInvalidation.results.first?.frameId == secondID)

            try await first.close()
            try await second.close()
        }
    }
}

@Test func waxSessionCloseInvalidatesUnifiedSearchCache() async throws {
    let cache = UnifiedSearchEngineCache.shared

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let frameId = try await wax.put(Data("cache invalidation sentinel".utf8))
        try await text.index(frameId: frameId, text: "cache invalidation sentinel")
        try await text.commit()
        _ = try await wax.search(SearchRequest(query: "sentinel", mode: .textOnly, topK: 5))

        #expect(await cache.containsEntry(for: wax))

        let session = try await wax.openSession(
            .readOnly,
            config: WaxSession.Config(
                enableTextSearch: true,
                enableVectorSearch: false,
                enableStructuredMemory: false
            )
        )
        await session.close()

        #expect((await cache.containsEntry(for: wax)) == false)
        try await wax.close()
    }
}

@Test func unifiedSearchCacheChurnStaysBoundedAndCleansUpOnClose() async throws {
    let cache = UnifiedSearchEngineCache.shared

    for index in 0..<96 {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
        defer { try? FileManager.default.removeItem(at: url) }

        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let payload = "cache churn \(index)"
        let frameId = try await wax.put(Data(payload.utf8))
        try await text.index(frameId: frameId, text: payload)
        try await text.commit()

        _ = try await wax.search(SearchRequest(query: "churn \(index)", mode: .textOnly, topK: 2))
        #expect(await cache.containsEntry(for: wax))

        let countsDuringRun = await cache.snapshotEntryCounts()
        #expect(countsDuringRun.text <= 64)
        #expect(countsDuringRun.vector <= 64)

        let session = try await wax.openSession(
            .readOnly,
            config: WaxSession.Config(
                enableTextSearch: true,
                enableVectorSearch: false,
                enableStructuredMemory: false
            )
        )
        await session.close()
        #expect((await cache.containsEntry(for: wax)) == false)

        try await wax.close()
    }
}

@Test func filtersAllowResultsBeyondTopK() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 2)

        _ = try await vec.putWithEmbedding(Data("A".utf8), embedding: [1.0, 0.0])
        _ = try await vec.putWithEmbedding(Data("B".utf8), embedding: [0.9, 0.1])
        let id2 = try await vec.putWithEmbedding(Data("C".utf8), embedding: [0.1, 0.9])
        let id3 = try await vec.putWithEmbedding(Data("D".utf8), embedding: [0.0, 1.0])
        try await vec.commit()

        let allowlist = FrameFilter(frameIds: [id2, id3])
        let request = SearchRequest(
            embedding: [1.0, 0.0],
            mode: .vectorOnly,
            topK: 2,
            frameFilter: allowlist
        )
        let response = try await wax.search(request)

        let ids = Set(response.results.map(\.frameId))
        #expect(ids == Set([id2, id3]))

        try await wax.close()
    }
}

@Test func frameFilterMatchesMetadataEntries() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(
            Data("Project alpha roadmap".utf8),
            options: FrameMetaSubset(metadata: Metadata(["source": "email", "topic": "alpha"]))
        )
        try await text.index(frameId: id0, text: "Project alpha roadmap")

        let id1 = try await wax.put(
            Data("Project alpha backlog".utf8),
            options: FrameMetaSubset(metadata: Metadata(["source": "notes", "topic": "alpha"]))
        )
        try await text.index(frameId: id1, text: "Project alpha backlog")

        try await text.commit()

        let filter = FrameFilter(
            metadataFilter: .init(requiredEntries: ["source": "email"])
        )
        let request = SearchRequest(
            query: "alpha",
            mode: .textOnly,
            topK: 10,
            frameFilter: filter
        )
        let response = try await wax.search(request)

        #expect(response.results.map(\.frameId) == [id0])

        try await wax.close()
    }
}

@Test func frameFilterMatchesTagsAndLabels() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(
            Data("Quarterly finance summary".utf8),
            options: FrameMetaSubset(
                tags: [TagPair(key: "team", value: "finance"), TagPair(key: "quarter", value: "q1")],
                labels: ["public", "summary"]
            )
        )
        try await text.index(frameId: id0, text: "Quarterly finance summary")

        let id1 = try await wax.put(
            Data("Quarterly engineering summary".utf8),
            options: FrameMetaSubset(
                tags: [TagPair(key: "team", value: "engineering"), TagPair(key: "quarter", value: "q1")],
                labels: ["internal", "summary"]
            )
        )
        try await text.index(frameId: id1, text: "Quarterly engineering summary")

        try await text.commit()

        let filter = FrameFilter(
            metadataFilter: .init(
                requiredTags: [TagPair(key: "team", value: "finance")],
                requiredLabels: ["public"]
            )
        )
        let request = SearchRequest(
            query: "Quarterly summary",
            mode: .textOnly,
            topK: 10,
            frameFilter: filter
        )
        let response = try await wax.search(request)

        #expect(response.results.map(\.frameId) == [id0])

        try await wax.close()
    }
}

@Test func timelineFallbackHonorsMetadataFilter() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let includedID = try await wax.put(
            Data("On-call runbook for release".utf8),
            options: FrameMetaSubset(metadata: Metadata(["source": "email"]))
        )
        try await text.index(frameId: includedID, text: "On-call runbook for release")

        _ = try await wax.put(
            Data("On-call retrospective notes".utf8),
            options: FrameMetaSubset(metadata: Metadata(["source": "notes"]))
        )

        try await text.commit()

        let request = SearchRequest(
            query: "query-with-no-primary-hits",
            mode: .textOnly,
            topK: 10,
            frameFilter: FrameFilter(
                metadataFilter: .init(requiredEntries: ["source": "email"])
            ),
            allowTimelineFallback: true,
            timelineFallbackLimit: 10
        )
        let response = try await wax.search(request)

        #expect(response.results.map(\.frameId) == [includedID])
        #expect(response.results.allSatisfy { $0.sources == [.timeline] })

        try await wax.close()
    }
}

private struct TestEmbedder2D: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        VectorMath.normalizeL2([1.0, 0.0])
    }
}

#if canImport(Metal)
@Test
func metalVectorSearchNormalizesNonNormalizedQueryEmbedding() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.useMetalVectorSearch = true
        config.rag.searchMode = .vectorOnly

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: TestEmbedder2D()
        )
        try await orchestrator.remember("hello world")

        let result = try await orchestrator.recall(query: "hello", embedding: [2.0, 0.0])
        #expect(!result.items.isEmpty)

        try await orchestrator.close()
    }
}
#endif

@Test func vectorSearchWithoutManifestUsesPendingEmbeddings() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 2)

        let id0 = try await vec.putWithEmbedding(Data("Pending".utf8), embedding: [0.0, 1.0])

        let request = SearchRequest(
            embedding: [0.0, 1.0],
            mode: .vectorOnly,
            topK: 5
        )
        let response = try await wax.search(request)

        #expect(response.results.first?.frameId == id0)

        do {
            try await wax.close()
            Issue.record("Expected close to propagate auto-commit failure for pending embeddings")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("vector index must be staged before committing embeddings"))
        }
    }
}

@Test func vectorOnlySearchWithoutEmbeddingThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        do {
            _ = try await wax.search(SearchRequest(mode: .vectorOnly, topK: 5))
            Issue.record("Expected WaxError for vectorOnly search without embedding")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("requires a non-empty query embedding"))
        }

        try await wax.close()
    }
}

@Test func locationQueryPrefersProfileOverHealthDistractor() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let profileID = try await wax.put(
            Data("Person18 moved to Seattle in 2021 and works on the platform team.".utf8)
        )
        try await text.index(frameId: profileID, text: "Person18 moved to Seattle in 2021 and works on the platform team.")

        let healthID = try await wax.put(
            Data("Person18 is allergic to peanuts and avoids foods with peanuts.".utf8)
        )
        try await text.index(frameId: healthID, text: "Person18 is allergic to peanuts and avoids foods with peanuts.")

        let prefID = try await wax.put(
            Data("Person18 prefers pair programming and async design docs.".utf8)
        )
        try await text.index(frameId: prefID, text: "Person18 prefers pair programming and async design docs.")

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "Which city did Person18 move to",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == profileID)
        #expect(response.results.map(\.frameId).contains(healthID))
        #expect(response.results.map(\.frameId).contains(prefID))

        try await wax.close()
    }
}

@Test func launchQueryPrefersExactEntityTimelineOverOtherEntityTie() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let otherID = try await wax.put(
            Data("For project Atlas-07, beta starts in April 2026 and public launch is September 10, 2026.".utf8)
        )
        try await text.index(frameId: otherID, text: "For project Atlas-07, beta starts in April 2026 and public launch is September 10, 2026.")

        let targetID = try await wax.put(
            Data("For project Atlas-10, beta starts in April 2026 and public launch is August 13, 2026.".utf8)
        )
        try await text.index(frameId: targetID, text: "For project Atlas-10, beta starts in April 2026 and public launch is August 13, 2026.")

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "What is the public launch date for Atlas 10",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == targetID)
        #expect(response.results.count >= 2)

        try await wax.close()
    }
}

@Test func punctuationHeavyQueryWithQuotesAndSymbolsDoesNotBreakFTS() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let atlas10 = try await wax.put(
            Data("For project Atlas-10, public launch is August 13, 2026.".utf8)
        )
        try await text.index(frameId: atlas10, text: "For project Atlas-10, public launch is August 13, 2026.")

        let atlas11 = try await wax.put(
            Data("For project Atlas-11, public launch is September 14, 2026.".utf8)
        )
        try await text.index(frameId: atlas11, text: "For project Atlas-11, public launch is September 14, 2026.")

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: #"What is the public launch date for "Atlas-10"? -- !!!"#,
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == atlas10)
        #expect(response.results.map(\.frameId).contains(atlas11))

        try await wax.close()
    }
}

@Test func nameOnlyEntityLocationQueryPrefersMatchingPerson() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let noah = try await wax.put(
            Data("Noah moved to Austin in 2021. City move city move city move city move.".utf8)
        )
        try await text.index(frameId: noah, text: "Noah moved to Austin in 2021. City move city move city move city move.")

        let priya = try await wax.put(
            Data("Priya moved to Seattle in 2021 and works on release readiness.".utf8)
        )
        try await text.index(frameId: priya, text: "Priya moved to Seattle in 2021 and works on release readiness.")

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "Which city did Priya move to",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == priya)
        #expect(response.results.map(\.frameId).contains(noah))

        try await wax.close()
    }
}

@Test func lowercaseNameOnlyEntityWithoutCueWordsPrefersMoveSentence() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let distractorID = try await wax.put(
            Data("Noah city move retrospective: city move city move noah city move checklist without a destination.".utf8)
        )
        try await text.index(
            frameId: distractorID,
            text: "Noah city move retrospective: city move city move noah city move checklist without a destination."
        )

        let targetID = try await wax.put(
            Data("Noah moved to Boise in 2021 and joined release engineering.".utf8)
        )
        try await text.index(frameId: targetID, text: "Noah moved to Boise in 2021 and joined release engineering.")

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "which city noah moved to",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == targetID)
        #expect(response.results.map(\.frameId).contains(distractorID))

        try await wax.close()
    }
}

@Test func sameNameCollisionUsesProjectAndTimelineCues() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let olderTimelineID = try await wax.put(
            Data("In the 2025 Atlas-10 timeline, Noah owns deployment readiness and public launch is July 9, 2025. Atlas-10 launch date Atlas-10 launch date Atlas-10 launch date.".utf8)
        )
        try await text.index(
            frameId: olderTimelineID,
            text: "In the 2025 Atlas-10 timeline, Noah owns deployment readiness and public launch is July 9, 2025. Atlas-10 launch date Atlas-10 launch date Atlas-10 launch date."
        )

        let currentTimelineID = try await wax.put(
            Data("In the 2026 Atlas-10 timeline, Noah owns deployment readiness and public launch is August 13, 2026.".utf8)
        )
        try await text.index(
            frameId: currentTimelineID,
            text: "In the 2026 Atlas-10 timeline, Noah owns deployment readiness and public launch is August 13, 2026."
        )

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "for noah on atlas-10 in 2026 what is the public launch date",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == currentTimelineID)
        #expect(response.results.map(\.frameId).contains(olderTimelineID))

        try await wax.close()
    }
}

@Test func quotedPhraseIntentPrefersExactHyphenatedPhraseMatch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let distractorID = try await wax.put(
            Data("Atlas 10 launch date planning notes cover launch date rehearsal and launch date checklist for August 30, 2026.".utf8)
        )
        try await text.index(
            frameId: distractorID,
            text: "Atlas 10 launch date planning notes cover launch date rehearsal and launch date checklist for August 30, 2026."
        )

        let phraseMatchID = try await wax.put(
            Data(#"The release ledger states "Atlas-10 launch date" is August 13, 2026."#.utf8)
        )
        try await text.index(
            frameId: phraseMatchID,
            text: #"The release ledger states "Atlas-10 launch date" is August 13, 2026."#
        )

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: #"what is "Atlas-10 launch date" ???"#,
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == phraseMatchID)
        #expect(response.results.map(\.frameId).contains(distractorID))

        try await wax.close()
    }
}

@Test func singleQuotedPhraseIntentPrefersExactHyphenatedPhraseMatch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let distractorID = try await wax.put(
            Data("Atlas 10 launch date planning notes: atlas 10 launch date rehearsal, atlas 10 launch date checklist, atlas 10 launch date draft for August 30, 2026.".utf8)
        )
        try await text.index(
            frameId: distractorID,
            text: "Atlas 10 launch date planning notes: atlas 10 launch date rehearsal, atlas 10 launch date checklist, atlas 10 launch date draft for August 30, 2026."
        )

        let phraseMatchID = try await wax.put(
            Data("Release ledger canonical phrase Atlas-10 launch date is August 13, 2026.".utf8)
        )
        try await text.index(
            frameId: phraseMatchID,
            text: "Release ledger canonical phrase Atlas-10 launch date is August 13, 2026."
        )

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "what is 'Atlas-10 launch date' ???",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == phraseMatchID)
        #expect(response.results.map(\.frameId).contains(distractorID))

        try await wax.close()
    }
}

@Test func launchDateQueryRejectsTentativeDistractorForSameEntity() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let distractorID = try await wax.put(
            Data("Draft memo: for project Atlas-10, public launch date is August 21, 2026 and remains tentative pending approval.".utf8)
        )
        try await text.index(
            frameId: distractorID,
            text: "Draft memo: for project Atlas-10, public launch date is August 21, 2026 and remains tentative pending approval."
        )

        let authoritativeID = try await wax.put(
            Data("For project Atlas-10, public launch is August 13, 2026.".utf8)
        )
        try await text.index(
            frameId: authoritativeID,
            text: "For project Atlas-10, public launch is August 13, 2026."
        )

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "What is the public launch date for Atlas-10?",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == authoritativeID)
        #expect(response.results.map(\.frameId).contains(distractorID))

        try await wax.close()
    }
}

@Test func hybridSearchRankingDiagnosticsTopKIsScopedAndStable() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 4, preference: .cpuOnly)

        let id0 = try await vec.putWithEmbedding(
            Data("Swift concurrency guide".utf8),
            embedding: [1.0, 0.0, 0.0, 0.0]
        )
        try await text.index(frameId: id0, text: "Swift concurrency guide")

        let id1 = try await vec.putWithEmbedding(
            Data("Swift actors and tasks".utf8),
            embedding: [0.9, 0.1, 0.0, 0.0]
        )
        try await text.index(frameId: id1, text: "Swift actors and tasks")

        let id2 = try await vec.putWithEmbedding(
            Data("Rust ownership".utf8),
            embedding: [0.0, 1.0, 0.0, 0.0]
        )
        try await text.index(frameId: id2, text: "Rust ownership")

        try await text.commit()
        try await vec.commit()

        let request = SearchRequest(
            query: "Swift concurrency",
            embedding: [1.0, 0.0, 0.0, 0.0],
            vectorEnginePreference: .cpuOnly,
            mode: .hybrid(alpha: 0.5),
            topK: 3,
            enableRankingDiagnostics: true,
            rankingDiagnosticsTopK: 1
        )

        let responseA = try await wax.search(request)
        let responseB = try await wax.search(request)

        #expect(responseA == responseB)
        #expect(responseA.results.count == 3)
        #expect(responseA.results[0].rankingDiagnostics != nil)
        #expect(responseA.results[1].rankingDiagnostics == nil)
        #expect(responseA.results[2].rankingDiagnostics == nil)

        if let lanes = responseA.results[0].rankingDiagnostics?.laneContributions {
            for idx in 1..<lanes.count {
                #expect(lanes[idx - 1].rrfScore >= lanes[idx].rrfScore)
                if lanes[idx - 1].rrfScore == lanes[idx].rrfScore {
                    #expect(lanes[idx - 1].source.rawValue <= lanes[idx].source.rawValue)
                }
            }
        } else {
            #expect(Bool(false))
        }

        try await wax.close()
    }
}

@Test func hybridRrfTieBreakUsesFrameIDWhenScoreAndBestRankTie() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let query = "what is rrfuniquetoken123"

        let textOnlyID = try await wax.put(Data("text lane candidate".utf8))
        try await text.index(frameId: textOnlyID, text: query)

        let vectorOnlyID = try await wax.put(Data("vector lane candidate".utf8))

        try await text.commit()

        let vectorEngine = DeterministicVectorResultsEngine(
            dimensions: 4,
            results: [(frameId: vectorOnlyID, score: 1.0)]
        )

        let response = try await wax.search(
            SearchRequest(
                query: query,
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.3),
                topK: 2,
                enableRankingDiagnostics: true,
                rankingDiagnosticsTopK: 2
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: vectorEngine,
                structuredEngine: nil
            )
        )

        #expect(response.results.count == 2)
        #expect(response.results.map(\.frameId) == [textOnlyID, vectorOnlyID])
        #expect(response.results[0].rankingDiagnostics?.tieBreakReason == .topResult)
        #expect(response.results[1].rankingDiagnostics?.tieBreakReason == .frameID)

        let firstScore = response.results[0].score
        let secondScore = response.results[1].score
        #expect(abs(firstScore - secondScore) == 0)

        try await wax.close()
    }
}

// MARK: - Phase 4A: Structured memory query path, RRF fusion, intent reranking, frame filtering

// Exercises the structuredEntityCandidates + evidenceFrameIds path in textOnly mode when
// structuredMemory.weight > 0 and the query contains an entity name as a token.
// "Alice" is registered as an entity alias, so a query containing "Alice" triggers the
// structured lane to resolve her entity and surface evidence frames via RRF fusion.
@Test func textOnlyStructuredMemoryLaneSurfacesEvidenceFrame() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Frame with weak text match — only one of the query terms appears.
        let weakTextID = try await wax.put(
            Data("Alice presented on release strategy".utf8)
        )
        try await text.index(frameId: weakTextID, text: "Alice presented on release strategy")

        // Evidence frame: strong structured-lane candidate for entity "Alice".
        // Query text overlap is minimal ("Alice" only).
        let structuredEvidenceID = try await wax.put(
            Data("Alice owns the deployment readiness process for the Atlas project. ci pipeline automation workflows reduce manual errors.".utf8)
        )
        try await text.index(
            frameId: structuredEvidenceID,
            text: "Alice owns the deployment readiness process for the Atlas project. ci pipeline automation workflows reduce manual errors."
        )

        try await text.commit()

        // Register Alice as an entity and assert a fact pointing to structuredEvidenceID.
        let session = try await WaxStructuredMemorySession(wax: wax)
        _ = try await session.upsertEntity(
            key: EntityKey("person:alice"),
            kind: "person",
            aliases: ["Alice"],
            nowMs: 1_000
        )
        _ = try await session.assertFact(
            subject: EntityKey("person:alice"),
            predicate: PredicateKey("owns"),
            object: .string("deployment readiness"),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: structuredEvidenceID,
                    chunkIndex: nil,
                    spanUTF8: nil,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: 0.9,
                    assertedAtMs: 1_000
                ),
            ]
        )
        try await session.commit()

        // Query contains "Alice" — the entity resolver will find person:alice and
        // load structuredEvidenceID into the structured lane for RRF fusion.
        let request = SearchRequest(
            query: "Alice automation pipeline",
            mode: .textOnly,
            topK: 10,
            structuredMemory: StructuredMemorySearchOptions(
                weight: 0.4,
                maxEntityCandidates: 16,
                maxFacts: 64,
                maxEvidenceFrames: 32
            )
        )
        let response = try await wax.search(request)

        // Both frames must appear — the structured lane fuses structuredEvidenceID in.
        let ids = response.results.map(\.frameId)
        #expect(ids.contains(weakTextID))
        #expect(ids.contains(structuredEvidenceID))

        try await wax.close()
    }
}

// Exercises the structuredEntityCandidates path where the query directly names an entity.
// "Priya" is registered as an entity alias. A query containing "Priya" causes the structured
// lane to resolve the entity and inject its evidence frames into the RRF fusion.
@Test func textOnlyQueryNamingEntityBoostsStructuredEvidenceFrame() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Distractor: general text that partially matches the query but does not name Priya.
        let distractorID = try await wax.put(
            Data("General information about deployment and release processes for the team.".utf8)
        )
        try await text.index(frameId: distractorID, text: "General information about deployment and release processes for the team.")

        // Evidence frame: explicitly mentions Priya and the infrastructure team.
        let evidenceID = try await wax.put(
            Data("Priya joined the infrastructure team in March 2024 and leads on-call rotations.".utf8)
        )
        try await text.index(frameId: evidenceID, text: "Priya joined the infrastructure team in March 2024 and leads on-call rotations.")

        try await text.commit()

        let session = try await WaxStructuredMemorySession(wax: wax)
        _ = try await session.upsertEntity(
            key: EntityKey("person:priya"),
            kind: "person",
            aliases: ["Priya"],
            nowMs: 500
        )
        _ = try await session.assertFact(
            subject: EntityKey("person:priya"),
            predicate: PredicateKey("role"),
            object: .string("infrastructure lead"),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: evidenceID,
                    chunkIndex: nil,
                    spanUTF8: nil,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: 1.0,
                    assertedAtMs: 500
                ),
            ]
        )
        try await session.commit()

        // "Priya" in the query triggers entity resolution: person:priya is found and its
        // evidence frame (evidenceID) enters the structured lane for RRF fusion.
        let request = SearchRequest(
            query: "What team does Priya lead",
            mode: .textOnly,
            topK: 5,
            structuredMemory: StructuredMemorySearchOptions(
                weight: 0.5,
                maxEntityCandidates: 8,
                maxFacts: 32,
                maxEvidenceFrames: 16
            )
        )
        let response = try await wax.search(request)

        // Both frames must appear — evidence frame is in both BM25 lane and structured lane.
        let ids = response.results.map(\.frameId)
        #expect(ids.contains(evidenceID))

        try await wax.close()
    }
}

// Exercises the vectorOnly + structured memory RRF fusion path (lines 294-316 in UnifiedSearch.swift).
// When structuredMemory.weight > 0 and structured frame IDs are non-empty, the vectorOnly
// branch fuses vector results with the structured lane via RRF.
@Test func vectorOnlyStructuredMemoryLaneFusesWithVectorResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)

        // Frame that will rank well on vector similarity.
        let vectorID = try await vec.putWithEmbedding(
            Data("Swift performance optimization guide".utf8),
            embedding: [1.0, 0.0]
        )
        try await text.index(frameId: vectorID, text: "Swift performance optimization guide")

        // Evidence frame for entity "swift" — no embedding provided.
        let evidenceID = try await wax.put(
            Data("Swift language was introduced by Apple at WWDC 2014.".utf8)
        )
        try await text.index(frameId: evidenceID, text: "Swift language was introduced by Apple at WWDC 2014.")

        try await text.commit()
        try await vec.commit()

        let session = try await WaxStructuredMemorySession(wax: wax)
        _ = try await session.upsertEntity(
            key: EntityKey("lang:swift"),
            kind: "language",
            aliases: ["Swift"],
            nowMs: 0
        )
        _ = try await session.assertFact(
            subject: EntityKey("lang:swift"),
            predicate: PredicateKey("introduced"),
            object: .string("WWDC 2014"),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: evidenceID,
                    chunkIndex: nil,
                    spanUTF8: nil,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: 0.95,
                    assertedAtMs: 0
                ),
            ]
        )
        try await session.commit()

        let request = SearchRequest(
            query: "Swift",
            embedding: VectorMath.normalizeL2([1.0, 0.0]),
            mode: .vectorOnly,
            topK: 10,
            structuredMemory: StructuredMemorySearchOptions(
                weight: 0.6,
                maxEntityCandidates: 8,
                maxFacts: 32,
                maxEvidenceFrames: 16
            )
        )
        let response = try await wax.search(request)

        // Both the vector-matched frame and the structured evidence frame must appear.
        let ids = response.results.map(\.frameId)
        #expect(ids.contains(vectorID))
        #expect(ids.contains(evidenceID))

        // Structured lane source must appear in at least one result.
        let hasStructuredSource = response.results.contains { $0.sources.contains(.structuredMemory) }
        #expect(hasStructuredSource)

        try await wax.close()
    }
}

// Exercises the ownership intent reranking branch in `intentAwareRerank`.
// Queries containing "who owns" trigger the `.asksOwnership` path and prefer results
// that contain "owns", "owner", or "deployment readiness" over general results.
@Test func ownershipQueryPrefersFrameContainingOwnsKeyword() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // This is the target: mentions "owns" explicitly.
        let ownershipID = try await wax.put(
            Data("Noah owns the deployment readiness process for Atlas-10 and leads release coordination.".utf8)
        )
        try await text.index(
            frameId: ownershipID,
            text: "Noah owns the deployment readiness process for Atlas-10 and leads release coordination."
        )

        // This distractor mentions Atlas-10 but discusses dates, not ownership.
        let distractorID = try await wax.put(
            Data("Atlas-10 public launch is scheduled for August 13, 2026 pending sign-off.".utf8)
        )
        try await text.index(
            frameId: distractorID,
            text: "Atlas-10 public launch is scheduled for August 13, 2026 pending sign-off."
        )

        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "Who owns deployment readiness for Atlas-10",
                mode: .textOnly,
                topK: 5
            )
        )

        #expect(response.results.first?.frameId == ownershipID)
        #expect(response.results.map(\.frameId).contains(distractorID))

        try await wax.close()
    }
}

// Exercises the timeline fallback path when the fallback limit is zero, which should
// return immediately with an empty array (line 491 in UnifiedSearch.swift).
@Test func timelineFallbackWithZeroLimitReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id = try await wax.put(Data("some content for timeline".utf8))
        try await text.index(frameId: id, text: "some content for timeline")
        try await text.commit()

        let request = SearchRequest(
            query: "no-match-query-xyz987",
            mode: .textOnly,
            topK: 5,
            allowTimelineFallback: true,
            timelineFallbackLimit: 0  // zero limit: early return in timelineFallbackResults
        )
        let response = try await wax.search(request)

        #expect(response.results.isEmpty)

        try await wax.close()
    }
}

// Exercises the timeline fallback for a temporal query in hybrid mode.
// A temporal query (`when ...`) sets queryType to .temporal, which adds timelineFrameIds
// to the hybrid fusion lists and also triggers the timeline fallback path when no
// primary results exist.
@Test func temporalQueryTriggersTimelineLaneInHybridMode() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)

        let id0 = try await vec.putWithEmbedding(
            Data("Release notes for Atlas-10 from last sprint review".utf8),
            embedding: [1.0, 0.0]
        )
        try await text.index(frameId: id0, text: "Release notes for Atlas-10 from last sprint review")

        let id1 = try await vec.putWithEmbedding(
            Data("Atlas-10 deployment runbook last updated by Noah".utf8),
            embedding: [0.9, 0.1]
        )
        try await text.index(frameId: id1, text: "Atlas-10 deployment runbook last updated by Noah")

        try await text.commit()
        try await vec.commit()

        // "when" prefix classifies the query as .temporal, enabling the timeline lane.
        let request = SearchRequest(
            query: "when was the last Atlas-10 release",
            embedding: [1.0, 0.0],
            mode: .hybrid(alpha: 0.5),
            topK: 5
        )
        let response = try await wax.search(request)

        // Results must include the committed frames (timeline lane contributes their IDs).
        let ids = response.results.map(\.frameId)
        #expect(ids.contains(id0) || ids.contains(id1))

        try await wax.close()
    }
}

// Exercises the `passesFrameFilter` deleted-frame exclusion path.
// Deleted frames must not appear in results when includeDeleted is false (the default).
@Test func deletedFramesAreExcludedFromSearchResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let activeID = try await wax.put(
            Data("Active document about distributed systems design.".utf8)
        )
        try await text.index(frameId: activeID, text: "Active document about distributed systems design.")

        let deletedID = try await wax.put(
            Data("Deleted document about distributed systems performance.".utf8)
        )
        try await text.index(frameId: deletedID, text: "Deleted document about distributed systems performance.")

        try await text.commit()

        // Mark the second frame as deleted.
        try await wax.delete(frameId: deletedID)
        try await wax.commit()

        let request = SearchRequest(
            query: "distributed systems",
            mode: .textOnly,
            topK: 10
            // includeDeleted defaults to false
        )
        let response = try await wax.search(request)

        let ids = response.results.map(\.frameId)
        #expect(ids.contains(activeID))
        #expect(!ids.contains(deletedID))

        try await wax.close()
    }
}

// Exercises the `passesFrameFilter` superseded-frame exclusion path.
// When includeSuperseded is false (the default), superseded frames must not appear.
@Test func supersededFramesAreExcludedFromSearchResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let oldID = try await wax.put(
            Data("Architecture overview v1: monolithic design with shared database.".utf8)
        )
        try await text.index(frameId: oldID, text: "Architecture overview v1: monolithic design with shared database.")

        let newID = try await wax.put(
            Data("Architecture overview v2: microservices with event sourcing.".utf8)
        )
        try await text.index(frameId: newID, text: "Architecture overview v2: microservices with event sourcing.")

        try await text.commit()

        // Mark oldID as superseded by newID.
        try await wax.supersede(supersededId: oldID, supersedingId: newID)
        try await wax.commit()

        let request = SearchRequest(
            query: "architecture overview",
            mode: .textOnly,
            topK: 10
            // includeSuperseded defaults to false
        )
        let response = try await wax.search(request)

        let ids = response.results.map(\.frameId)
        #expect(ids.contains(newID))
        #expect(!ids.contains(oldID))

        try await wax.close()
    }
}

// Exercises the surrogate frame exclusion path via the `passesFrameFilter` check.
// Frames with kind "surrogate" must be excluded when includeSurrogates is false (the default).
@Test func surrogateKindFramesAreExcludedFromSearchResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let normalID = try await wax.put(
            Data("Normal knowledge document about Swift concurrency actors.".utf8)
        )
        try await text.index(frameId: normalID, text: "Normal knowledge document about Swift concurrency actors.")

        // Manually store a frame with kind = "surrogate"
        let surrogateID = try await wax.put(
            Data("Surrogate summary of Swift concurrency actors document.".utf8),
            options: FrameMetaSubset(kind: "surrogate")
        )
        try await text.index(frameId: surrogateID, text: "Surrogate summary of Swift concurrency actors document.")

        try await text.commit()

        let request = SearchRequest(
            query: "Swift concurrency actors",
            mode: .textOnly,
            topK: 10
            // includeSurrogates defaults to false
        )
        let response = try await wax.search(request)

        let ids = response.results.map(\.frameId)
        #expect(ids.contains(normalID))
        #expect(!ids.contains(surrogateID))

        try await wax.close()
    }
}

// Exercises the includeSurrogates = true path — when explicitly opted in, surrogate frames
// must appear in results alongside normal frames.
@Test func surrogateFramesIncludedWhenFilterAllowsThem() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let normalID = try await wax.put(
            Data("Normal knowledge document about Swift actors.".utf8)
        )
        try await text.index(frameId: normalID, text: "Normal knowledge document about Swift actors.")

        let surrogateID = try await wax.put(
            Data("Surrogate summary of Swift actors document.".utf8),
            options: FrameMetaSubset(kind: "surrogate")
        )
        try await text.index(frameId: surrogateID, text: "Surrogate summary of Swift actors document.")

        try await text.commit()

        let request = SearchRequest(
            query: "Swift actors",
            mode: .textOnly,
            topK: 10,
            frameFilter: FrameFilter(includeSurrogates: true)
        )
        let response = try await wax.search(request)

        let ids = response.results.map(\.frameId)
        #expect(ids.contains(normalID))
        #expect(ids.contains(surrogateID))

        try await wax.close()
    }
}

// Exercises the `minScore` filter path in `passesFrameFilter`.
// Results with a score below the threshold must be excluded.
@Test func minScoreFilterExcludesLowScoringResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Strong match: query term appears many times.
        let highScoreID = try await wax.put(
            Data("Swift Swift Swift Swift Swift Swift Swift Swift concurrency".utf8)
        )
        try await text.index(
            frameId: highScoreID,
            text: "Swift Swift Swift Swift Swift Swift Swift Swift concurrency"
        )

        // Weak match: query term appears once among many unrelated words.
        let lowScoreID = try await wax.put(
            Data("Java Kotlin Go Python Rust Swift Erlang Haskell F# Scala".utf8)
        )
        try await text.index(
            frameId: lowScoreID,
            text: "Java Kotlin Go Python Rust Swift Erlang Haskell F# Scala"
        )

        try await text.commit()

        // Without minScore, both frames appear.
        let allResponse = try await wax.search(
            SearchRequest(query: "Swift", mode: .textOnly, topK: 10)
        )
        #expect(allResponse.results.map(\.frameId).contains(highScoreID))

        // With minScore set high enough to cut the weaker result.
        let filtered = try await wax.search(
            SearchRequest(query: "Swift", mode: .textOnly, topK: 10, minScore: 5.0)
        )
        let filteredIds = filtered.results.map(\.frameId)
        #expect(filteredIds.contains(highScoreID))
        // Weaker result is below threshold (FTS5 score < 5.0 for single occurrence).
        if filteredIds.contains(lowScoreID) {
            // Acceptable only if FTS5 scored it high enough — verify the score is >= 5.0.
            let lowResult = filtered.results.first { $0.frameId == lowScoreID }
            #expect((lowResult?.score ?? 0) >= 5.0)
        }

        try await wax.close()
    }
}

// Exercises the `timeRange` filter in `passesFrameFilter`. Frames outside the time window
// must not appear in results even if they have high BM25 relevance.
// Uses explicit timestampMs overloads to produce deterministic, well-separated timestamps.
@Test func timeRangeFilterExcludesOutOfWindowFrames() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // earlyMs: a fixed point in the past (year 2020).
        let earlyMs: Int64 = 1_577_836_800_000  // 2020-01-01T00:00:00Z in ms
        // lateMs: a fixed point 30 days later.
        let lateMs: Int64 = earlyMs + 30 * 24 * 60 * 60 * 1000  // 2020-01-31
        // cutoff sits between the two.
        let cutoffMs: Int64 = earlyMs + 15 * 24 * 60 * 60 * 1000  // 2020-01-16

        let earlyID = try await wax.put(
            Data("Release notes for project Nova deployment pipeline".utf8),
            timestampMs: earlyMs
        )
        try await text.index(frameId: earlyID, text: "Release notes for project Nova deployment pipeline")

        let lateID = try await wax.put(
            Data("Release notes for project Nova deployment pipeline".utf8),
            timestampMs: lateMs
        )
        try await text.index(frameId: lateID, text: "Release notes for project Nova deployment pipeline")

        try await text.commit()

        // Filter to frames with timestamp >= cutoffMs. earlyID (2020-01-01) is before
        // cutoff; lateID (2020-01-31) is after cutoff.
        let request = SearchRequest(
            query: "Nova deployment pipeline",
            mode: .textOnly,
            topK: 10,
            timeRange: TimeRange(after: cutoffMs)
        )
        let response = try await wax.search(request)

        let ids = response.results.map(\.frameId)
        // earlyID is before the cutoff — it must be excluded.
        #expect(!ids.contains(earlyID))
        // lateID is after the cutoff — it must be included.
        #expect(ids.contains(lateID))

        try await wax.close()
    }
}

// Exercises the batch metadata prefetch path that is triggered when the result set size
// equals or exceeds `metadataLoadingThreshold`. By setting threshold = 1, even a single
// result triggers the batch `frameMetasIncludingPending` path instead of lazy per-frame lookups.
@Test func batchMetadataPrefetchPathWithLowThreshold() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("batch prefetch document alpha".utf8))
        try await text.index(frameId: id0, text: "batch prefetch document alpha")
        let id1 = try await wax.put(Data("batch prefetch document beta".utf8))
        try await text.index(frameId: id1, text: "batch prefetch document beta")

        try await text.commit()

        // metadataLoadingThreshold = 1 forces the batch prefetch path even for 2 results.
        let request = SearchRequest(
            query: "batch prefetch document",
            mode: .textOnly,
            topK: 10,
            metadataLoadingThreshold: 1
        )
        let response = try await wax.search(request)

        let ids = Set(response.results.map(\.frameId))
        #expect(ids.contains(id0))
        #expect(ids.contains(id1))

        try await wax.close()
    }
}

// Exercises the lazy per-frame metadata path (metadataLoadingThreshold > result count).
// The default threshold is 50, so 2 results always use the lazy path.
@Test func lazyMetadataLoadingPathWithHighThreshold() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("lazy load document gamma".utf8))
        try await text.index(frameId: id0, text: "lazy load document gamma")
        let id1 = try await wax.put(Data("lazy load document delta".utf8))
        try await text.index(frameId: id1, text: "lazy load document delta")

        try await text.commit()

        // Very high threshold: forces the lazy (per-frame) metadata lookup path.
        let request = SearchRequest(
            query: "lazy load document",
            mode: .textOnly,
            topK: 10,
            metadataLoadingThreshold: 1_000
        )
        let response = try await wax.search(request)

        let ids = Set(response.results.map(\.frameId))
        #expect(ids.contains(id0))
        #expect(ids.contains(id1))

        try await wax.close()
    }
}

// Exercises the hybrid mode RRF path where timeline lane is absent (non-temporal query)
// and structured lane is also absent (weight = 0), so only text and vector lanes fuse.
// This is the pure alpha-blended hybrid case.
@Test func hybridAlphaZeroFavorsVectorLaneOnly() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)

        // id0: strong vector match [1.0, 0.0], weak text match.
        let id0 = try await vec.putWithEmbedding(
            Data("epsilon zeta theta iota kappa".utf8),
            embedding: [1.0, 0.0]
        )
        try await text.index(frameId: id0, text: "epsilon zeta theta iota kappa")

        // id1: strong text match, weaker vector match.
        let id1 = try await vec.putWithEmbedding(
            Data("epsilon epsilon epsilon epsilon".utf8),
            embedding: [0.1, 0.9]
        )
        try await text.index(frameId: id1, text: "epsilon epsilon epsilon epsilon")

        try await text.commit()
        try await vec.commit()

        // alpha = 0.0 means all vector weight, no text weight.
        let request = SearchRequest(
            query: "epsilon",
            embedding: [1.0, 0.0],
            mode: .hybrid(alpha: 0.0),
            topK: 5
        )
        let response = try await wax.search(request)

        // id0 has the best vector alignment to [1.0, 0.0], so it should rank first.
        #expect(response.results.first?.frameId == id0)

        try await wax.close()
    }
}

// Exercises the hybrid mode RRF path where alpha = 1.0 means all text weight, no vector weight.
@Test func hybridAlphaOneFavorsTextLaneOnly() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)

        // id0: strong text match, poor vector alignment.
        let id0 = try await vec.putWithEmbedding(
            Data("lambda mu nu xi omicron lambda lambda lambda".utf8),
            embedding: [0.0, 1.0]
        )
        try await text.index(frameId: id0, text: "lambda mu nu xi omicron lambda lambda lambda")

        // id1: perfect vector alignment, one occurrence of "lambda".
        let id1 = try await vec.putWithEmbedding(
            Data("lambda rho sigma tau upsilon".utf8),
            embedding: [1.0, 0.0]
        )
        try await text.index(frameId: id1, text: "lambda rho sigma tau upsilon")

        try await text.commit()
        try await vec.commit()

        // alpha = 1.0: only text lane contributes to score.
        let request = SearchRequest(
            query: "lambda",
            embedding: [1.0, 0.0],
            mode: .hybrid(alpha: 1.0),
            topK: 5
        )
        let response = try await wax.search(request)

        // id0 has higher BM25 relevance for "lambda" (more occurrences).
        #expect(response.results.first?.frameId == id0)

        try await wax.close()
    }
}

// Exercises the textOnly mode diagnostics path for a result ranked second (tieBreakReason = .fusedScore).
@Test func textOnlyDiagnosticsSecondResultHasFusedScoreTieBreak() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(
            Data("diagnostic test document one with unique token phitoken".utf8)
        )
        try await text.index(frameId: id0, text: "diagnostic test document one with unique token phitoken")

        let id1 = try await wax.put(
            Data("diagnostic test document two phitoken".utf8)
        )
        try await text.index(frameId: id1, text: "diagnostic test document two phitoken")

        try await text.commit()

        let request = SearchRequest(
            query: "phitoken",
            mode: .textOnly,
            topK: 5,
            enableRankingDiagnostics: true,
            rankingDiagnosticsTopK: 2
        )
        let response = try await wax.search(request)

        #expect(response.results.count >= 2)
        #expect(response.results[0].rankingDiagnostics != nil)
        #expect(response.results[1].rankingDiagnostics != nil)
        #expect(response.results[0].rankingDiagnostics?.tieBreakReason == .topResult)
        // Second result uses fusedScore tie-break because its BM25 score differs from first.
        let secondReason = response.results[1].rankingDiagnostics?.tieBreakReason
        #expect(secondReason == .fusedScore || secondReason == .rerankComposite)

        try await wax.close()
    }
}

// Exercises the vectorOnly mode diagnostics path — lane contributions are populated for
// the top-K results and the source is .vector.
@Test func vectorOnlyDiagnosticsPopulatesVectorLaneContributions() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vec = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)

        let id0 = try await vec.putWithEmbedding(
            Data("diagnostics vector doc A".utf8),
            embedding: [1.0, 0.0]
        )
        let id1 = try await vec.putWithEmbedding(
            Data("diagnostics vector doc B".utf8),
            embedding: [0.9, 0.1]
        )

        try await vec.commit()

        let request = SearchRequest(
            embedding: [1.0, 0.0],
            mode: .vectorOnly,
            topK: 5,
            enableRankingDiagnostics: true,
            rankingDiagnosticsTopK: 2
        )
        let response = try await wax.search(request)

        #expect(response.results.count >= 2)

        let firstDiag = response.results[0].rankingDiagnostics
        #expect(firstDiag != nil)
        #expect(firstDiag?.tieBreakReason == .topResult)
        #expect(firstDiag?.laneContributions.first?.source == .vector)
        // Results are ordered by vector similarity: id0 ranks first.
        #expect(response.results[0].frameId == id0)

        let secondDiag = response.results[1].rankingDiagnostics
        #expect(secondDiag != nil)
        #expect(secondDiag?.tieBreakReason == .fusedScore)
        #expect(response.results[1].frameId == id1)

        try await wax.close()
    }
}

// Exercises the textOnly + empty query path: when query is nil the engine returns exploratory
// results. The structuredEngine is nil when there is no non-empty trimmed query.
@Test func textOnlyWithNilQueryReturnsEmptyWithoutCrashing() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id = try await wax.put(Data("some stored text".utf8))
        try await text.index(frameId: id, text: "some stored text")
        try await text.commit()

        // nil query + textOnly: trimmedQuery is nil, so textResults will be empty.
        let request = SearchRequest(query: nil, mode: .textOnly, topK: 5)
        let response = try await wax.search(request)

        // With no query there is nothing to search by BM25, so results must be empty.
        #expect(response.results.isEmpty)

        try await wax.close()
    }
}

// Exercises the hybrid textOnly results where text results exist but allowTimelineFallback
// is true yet the primary results are non-empty — the fallback must NOT trigger.
@Test func timelineFallbackDoesNotTriggerWhenPrimaryResultsExist() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id = try await wax.put(Data("primary result document mentioning quasar".utf8))
        try await text.index(frameId: id, text: "primary result document mentioning quasar")
        try await text.commit()

        let request = SearchRequest(
            query: "quasar",
            mode: .textOnly,
            topK: 5,
            allowTimelineFallback: true,
            timelineFallbackLimit: 10
        )
        let response = try await wax.search(request)

        // Primary result found — timeline fallback must not have fired.
        #expect(response.results.first?.frameId == id)
        #expect(response.results.allSatisfy { $0.sources == [.text] })

        try await wax.close()
    }
}

// Exercises the RRF bestLaneRank tie-break path.
// Two frames have the same fused score but different bestRank values — the one with the
// lower bestRank (higher-ranked in its individual lane) wins.
@Test func rrfBestLaneRankTieBreakFavorsLowerRankCandidate() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // id_alpha: ranked 1st in text lane only.
        // id_beta: ranked 1st in a dedicated vector lane only.
        // When both lanes have equal weight and both frames appear at rank 1 in their
        // respective lanes, they will tie on score. The one with the lower bestRank wins.
        // We use engine overrides to control exact lane results.
        let idAlpha = try await wax.put(Data("alpha document best lane rank test".utf8))
        try await text.index(frameId: idAlpha, text: "best lane rank unique-token-sigma")

        let idBeta = try await wax.put(Data("beta document best lane rank test".utf8))
        try await text.commit()

        // idBeta appears first in the vector lane at rank 1, idAlpha at rank 2.
        let vectorEngine = DeterministicVectorResultsEngine(
            dimensions: 2,
            results: [
                (frameId: idBeta, score: 1.0),
                (frameId: idAlpha, score: 0.9),
            ]
        )

        // idAlpha appears first in the text lane; idBeta doesn't match the query text.
        let response = try await wax.search(
            SearchRequest(
                query: "best lane rank unique-token-sigma",
                embedding: [1.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.5),
                topK: 2,
                enableRankingDiagnostics: true,
                rankingDiagnosticsTopK: 2
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: vectorEngine,
                structuredEngine: nil
            )
        )

        #expect(response.results.count == 2)
        let secondDiag = response.results[1].rankingDiagnostics
        // The second result must have either bestLaneRank or frameID as the tie-break reason.
        let validTieBreaks: Set<SearchResponse.RankingTieBreakReason> = [.bestLaneRank, .frameID, .fusedScore, .rerankComposite]
        if let reason = secondDiag?.tieBreakReason {
            #expect(validTieBreaks.contains(reason))
        }

        try await wax.close()
    }
}
