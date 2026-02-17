import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
import Wax

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
