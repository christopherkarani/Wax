import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch
import WaxVectorSearch

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

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 10, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        let response = try await wax.search(request)

        #expect(response.results.count == 1)
        #expect(response.results[0].frameId == id0)
        #expect(response.results[0].previewText != nil)

        try await wax.close()
    }
}

@Test func textOnlyMinScoreUsesNormalizedTextScores() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let exact = try await wax.put(Data("Swift Swift Swift concurrency actors".utf8))
        try await text.index(frameId: exact, text: "Swift Swift Swift concurrency actors")
        let weaker = try await wax.put(Data("Swift concurrency".utf8))
        try await text.index(frameId: weaker, text: "Swift concurrency")

        try await text.commit()

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 10, minScore: 0.9, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        let response = try await wax.search(request)

        #expect(response.results.map(\.frameId) == [exact])
        #expect(response.results.first?.score ?? 0 > 0.9)

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
        let request = SearchRequest(embedding: queryEmbedding, mode: .vectorOnly, topK: 10, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
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
            topK: 10,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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

        let request = SearchRequest(query: "Swift", mode: .textOnly, topK: 0, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        let response = try await wax.search(request)

        #expect(response.results.isEmpty)

        try await wax.close()
    }
}

@Test func structuredSearchTimeRangeBeforeDoesNotOverrideExplicitAsOf() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        let session = try await wax.openSession(.readWrite(.fail), config: config)

        let frameTimestampMs: Int64 = 100
        let factSystemFromMs: Int64 = 5_000
        let evidenceFrame = try await session.put(
            Data("Structured evidence payload without the entity alias.".utf8),
            options: FrameMetaSubset(searchText: "Structured evidence payload"),
            timestampMs: frameTimestampMs
        )
        try await session.indexText(frameId: evidenceFrame, text: "Structured evidence payload")

        _ = try await session.upsertEntity(
            key: EntityKey("person:f027-alice"),
            kind: "person",
            aliases: ["F027 Alice"],
            nowMs: factSystemFromMs
        )

        _ = try await session.assertFact(
            subject: EntityKey("person:f027-alice"),
            predicate: PredicateKey("status"),
            object: .string("active"),
            valid: StructuredTimeRange(fromMs: 0),
            system: StructuredTimeRange(fromMs: factSystemFromMs),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: evidenceFrame,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: 1,
                    assertedAtMs: factSystemFromMs
                ),
            ]
        )
        try await session.commit()

        let latestResponse = try await session.search(
            SearchRequest(
                query: "F027 Alice",
                mode: .textOnly,
                topK: 5,
                timeRange: SearchTimeRange(before: 200),
                asOfMs: .max,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        #expect(latestResponse.results.map(\.frameId) == [evidenceFrame])
        #expect(latestResponse.results.first?.sources == [.structured])

        let outOfFrameRangeResponse = try await session.search(
            SearchRequest(
                query: "F027 Alice",
                mode: .textOnly,
                topK: 5,
                timeRange: SearchTimeRange(before: 50),
                asOfMs: .max,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        #expect(outOfFrameRangeResponse.results.isEmpty)

        let historicalResponse = try await session.search(
            SearchRequest(
                query: "F027 Alice",
                mode: .textOnly,
                topK: 5,
                asOfMs: 200,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        #expect(historicalResponse.results.isEmpty)

        await session.close()
        try await wax.close()
    }
}

@Test func structuredSearchFindsEvidenceWhenEntityCandidateIsFactObject() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        let session = try await wax.openSession(.readWrite(.fail), config: config)

        let evidenceFrame = try await session.put(
            Data("Structured evidence payload without the target alias.".utf8),
            options: FrameMetaSubset(searchText: "Structured evidence payload")
        )
        try await session.indexText(frameId: evidenceFrame, text: "Structured evidence payload")

        _ = try await session.upsertEntity(
            key: EntityKey("person:f025-alice"),
            kind: "person",
            aliases: ["F025SubjectAlice"],
            nowMs: 1_000
        )
        _ = try await session.upsertEntity(
            key: EntityKey("place:f025-paris"),
            kind: "place",
            aliases: ["F025ObjectParis"],
            nowMs: 1_000
        )

        _ = try await session.assertFact(
            subject: EntityKey("person:f025-alice"),
            predicate: PredicateKey("located_in"),
            object: .entity(EntityKey("place:f025-paris")),
            valid: StructuredTimeRange(fromMs: 0),
            system: StructuredTimeRange(fromMs: 1_000),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: evidenceFrame,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: 1,
                    assertedAtMs: 1_000
                ),
            ]
        )
        try await session.commit()

        let response = try await session.search(
            SearchRequest(query: "F025ObjectParis", mode: .textOnly, topK: 5, asOfMs: .max, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        )

        #expect(response.results.map(\.frameId) == [evidenceFrame])
        #expect(response.results.first?.sources == [.structured])

        await session.close()
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
            frameFilter: allowlist,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
            frameFilter: filter,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let response = try await wax.search(request)

        #expect(response.results.map(\.frameId) == [id0])

        try await wax.close()
    }
}

@Test func metadataFilterOverfetchesPastInitialTextCandidateWindow() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let query = "f030starvation"

        for index in 0..<12 {
            let repeated = Array(repeating: query, count: 12).joined(separator: " ")
            let payload = "blocked \(index) \(repeated)"
            let frameID = try await wax.put(
                Data(payload.utf8),
                options: FrameMetaSubset(metadata: Metadata(["scope": "blocked"]))
            )
            try await text.index(frameId: frameID, text: payload)
        }

        let allowedFrame = try await wax.put(
            Data("allowed \(query)".utf8),
            options: FrameMetaSubset(metadata: Metadata(["scope": "allowed"]))
        )
        try await text.index(frameId: allowedFrame, text: "allowed \(query)")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: query,
                mode: .textOnly,
                topK: 1,
                frameFilter: FrameFilter(
                    metadataFilter: MetadataFilter(requiredEntries: ["scope": "allowed"])
                ),
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        #expect(response.results.map(\.frameId) == [allowedFrame])

        try await wax.close()
    }
}

@Test func metadataFilterOverfetchesPastInitialVectorCandidateWindow() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        var vectorResults: [(frameId: UInt64, score: Float)] = []
        for index in 0..<12 {
            let frameID = try await wax.put(
                Data("blocked vector candidate \(index)".utf8),
                options: FrameMetaSubset(metadata: Metadata(["scope": "blocked"]))
            )
            vectorResults.append((frameId: frameID, score: Float(100 - index)))
        }

        let allowedFrame = try await wax.put(
            Data("allowed vector candidate".utf8),
            options: FrameMetaSubset(metadata: Metadata(["scope": "allowed"]))
        )
        vectorResults.append((frameId: allowedFrame, score: 1))

        let vectorEngine = DeterministicVectorResultsEngine(dimensions: 4, results: vectorResults)
        let response = try await wax.search(
            SearchRequest(
                embedding: [1.0, 0.0, 0.0, 0.0],
                mode: .vectorOnly,
                topK: 1,
                frameFilter: FrameFilter(
                    metadataFilter: MetadataFilter(requiredEntries: ["scope": "allowed"])
                ),
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: vectorEngine,
                structuredEngine: nil
            )
        )

        #expect(response.results.map(\.frameId) == [allowedFrame])

        try await wax.close()
    }
}

@Test func metadataFilterCandidateLimitNeverDropsBelowRequestedTopK() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let vectorResults = (0..<1_100).map { index in
            (frameId: UInt64(index), score: Float(2_000 - index))
        }
        let vectorEngine = DeterministicVectorResultsEngine(dimensions: 4, results: vectorResults)

        for index in 0..<1_100 {
            _ = try await wax.put(
                Data("allowed large topK candidate \(index)".utf8),
                options: FrameMetaSubset(metadata: Metadata(["scope": "allowed"]))
            )
        }

        let response = try await wax.search(
            SearchRequest(
                embedding: [1.0, 0.0, 0.0, 0.0],
                mode: .vectorOnly,
                topK: 1_100,
                frameFilter: FrameFilter(
                    metadataFilter: MetadataFilter(requiredEntries: ["scope": "allowed"])
                ),
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: vectorEngine,
                structuredEngine: nil
            )
        )

        #expect(response.results.count == 1_100)

        try await wax.close()
    }
}

@Test func pendingMetadataFilteredResultUsesPendingPayloadPreview() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let pendingText = "pending preview f031 unique payload"
        let frameID = try await wax.put(
            Data(pendingText.utf8),
            options: FrameMetaSubset(metadata: Metadata(["scope": "pending"]))
        )
        let vectorEngine = DeterministicVectorResultsEngine(
            dimensions: 4,
            results: [(frameId: frameID, score: 1)]
        )

        let response = try await wax.search(
            SearchRequest(
                embedding: [1.0, 0.0, 0.0, 0.0],
                mode: .vectorOnly,
                topK: 1,
                frameFilter: FrameFilter(
                    metadataFilter: MetadataFilter(requiredEntries: ["scope": "pending"])
                ),
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: vectorEngine,
                structuredEngine: nil
            )
        )

        #expect(response.results.map(\.frameId) == [frameID])
        #expect(response.results.first?.previewText == pendingText)

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
            frameFilter: filter,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
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
        config.vectorEnginePreference = .auto
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
            topK: 5,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
            _ = try await wax.search(SearchRequest(mode: .vectorOnly, topK: 5, nowMs: Int64(Date().timeIntervalSince1970 * 1000)))
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
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
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
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
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
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

@Test func semanticScopeRerankPrefersRepoDecisionMemory() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let globalID = try await wax.put(
            Data("Auth rollout decision uses refresh tokens.".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "note",
                "wax.durability": "working",
                "wax.repo": "other-repo",
                "wax.project": "other-repo",
            ]))
        )
        try await text.index(frameId: globalID, text: "Auth rollout decision uses refresh tokens.")

        let repoID = try await wax.put(
            Data("Auth rollout decision uses refresh tokens.".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "decision",
                "wax.durability": "durable",
                "wax.repo": "Wax",
                "wax.project": "Wax",
            ]))
        )
        try await text.index(frameId: repoID, text: "Auth rollout decision uses refresh tokens.")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "auth rollout decision",
                mode: .textOnly,
                topK: 2,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            )
        )

        #expect(response.results.map(\.frameId).first == repoID)
        #expect(response.results.first?.explanations.contains("same repo") == true)
        #expect(response.results.first?.explanations.contains("decision memory") == true)

        try await wax.close()
    }
}

@Test func expiredMemoriesAreExcludedFromUnifiedSearch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let expiredID = try await wax.put(
            Data("Legacy rollout note".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "task_state",
                "wax.durability": "ephemeral",
                "wax.created_at_ms": String(nowMs - 10_000),
                "wax.expires_at_ms": String(nowMs - 1_000),
            ]))
        )
        try await text.index(frameId: expiredID, text: "Legacy rollout note")

        let activeID = try await wax.put(
            Data("Current rollout note".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "decision",
                "wax.durability": "durable",
                "wax.created_at_ms": String(nowMs),
            ]))
        )
        try await text.index(frameId: activeID, text: "Current rollout note")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(query: "rollout note", mode: .textOnly, topK: 5, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        )

        #expect(response.results.map(\.frameId).contains(activeID))
        #expect(!response.results.map(\.frameId).contains(expiredID))

        try await wax.close()
    }
}

@Test func unifiedSearchExplainsSemanticReasons() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let frameID = try await wax.put(
            Data("Chris prefers concise release notes.".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "user_preference",
                "wax.durability": "durable",
                "wax.repo": "Wax",
                "wax.project": "Wax",
            ]))
        )
        try await text.index(frameId: frameID, text: "Chris prefers concise release notes.")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "concise release notes",
                mode: .textOnly,
                topK: 3,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            )
        )

        let explanations = response.results.first?.explanations ?? []
        #expect(explanations.contains("keyword match"))
        #expect(explanations.contains("same repo"))
        #expect(explanations.contains("user preference"))

        try await wax.close()
    }
}

/// Identifier-like queries (caps + hyphens) must rank the frame that contains the
/// exact token first in text and hybrid. FTS `unicode61` splits hyphens, so similar
/// “stress canary” prose can otherwise win BM25. Vector-only is intentionally
/// unchecked: embeddings do not preserve unique hyphenated identifiers.
@Test func hyphenatedIdentifierQueryRanksExactTokenFrameFirstInTextAndHybrid() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let token = "WAXSTRESS-DURABLE-CANARY-ALPHA-8821"
        let exactBody = "Durable canary frame records unique token \(token) for retrieval."
        let neighborBody =
            "Grok Wax MCP stress canary 20260819 notes a durable canary alpha stress test without the unique hyphenated identifier."

        let neighborID = try await wax.put(
            Data(neighborBody.utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "decision",
                "wax.durability": "durable",
                "wax.repo": "Wax",
                "wax.project": "Wax",
            ]))
        )
        try await text.index(frameId: neighborID, text: neighborBody)

        let exactID = try await wax.put(
            Data(exactBody.utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "note",
                "wax.durability": "durable",
                "wax.repo": "other-repo",
                "wax.project": "other-project",
            ]))
        )
        try await text.index(frameId: exactID, text: exactBody)
        try await text.commit()

        let textResponse = try await wax.search(
            SearchRequest(
                query: token,
                mode: .textOnly,
                topK: 5,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            )
        )
        #expect(textResponse.results.first?.frameId == exactID)

        let hybridResponse = try await wax.search(
            SearchRequest(
                query: token,
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.5),
                topK: 5,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: DeterministicVectorResultsEngine(
                    dimensions: 4,
                    results: [(frameId: neighborID, score: 0.99)]
                ),
                structuredEngine: nil
            )
        )
        #expect(hybridResponse.results.first?.frameId == exactID)

        try await wax.close()
    }
}

/// Fused hybrid ranking can bury an exclusive-text identifier under several
/// same-repo vector neighbors. The exact-token pass must run on an overfetched
/// window, not only the published topK cut.
@Test func hyphenatedIdentifierQueryBeatsMultipleSameRepoHybridNeighbors() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let token = "WAXSTRESS-DURABLE-CANARY-ALPHA-8821"
        let neighborMeta = FrameMetaSubset(metadata: Metadata([
            "wax.memory_type": "decision",
            "wax.durability": "durable",
            "wax.repo": "Wax",
            "wax.project": "Wax",
        ]))

        var neighborIDs: [UInt64] = []
        neighborIDs.reserveCapacity(6)
        for index in 0..<6 {
            let body =
                "Grok Wax MCP stress canary neighbor \(index) records durable canary alpha stress notes without the unique hyphenated identifier."
            let neighborID = try await wax.put(Data(body.utf8), options: neighborMeta)
            try await text.index(frameId: neighborID, text: body)
            neighborIDs.append(neighborID)
        }

        let exactBody = "Durable canary frame records unique token \(token) for retrieval."
        let exactID = try await wax.put(
            Data(exactBody.utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "note",
                "wax.durability": "durable",
                "wax.repo": "other-repo",
                "wax.project": "other-project",
            ]))
        )
        try await text.index(frameId: exactID, text: exactBody)
        try await text.commit()

        let vectorHits = neighborIDs.enumerated().map { index, frameId in
            (frameId: frameId, score: Float(0.99) - Float(index) * 0.01)
        }

        let hybridResponse = try await wax.search(
            SearchRequest(
                query: token,
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.5),
                topK: 5,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: DeterministicVectorResultsEngine(
                    dimensions: 4,
                    results: vectorHits
                ),
                structuredEngine: nil
            )
        )
        #expect(hybridResponse.results.count <= 5)
        #expect(hybridResponse.results.first?.frameId == exactID)

        try await wax.close()
    }
}

/// vectorOnly must not overfetch or exact-match-rerank an identifier query.
/// A buried exact-token frame past the published topK cut stays unpublished.
@Test func vectorOnlyIdentifierQueryDoesNotPromoteExactFramePastPublishedTopK() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let token = "WAXSTRESS-DURABLE-CANARY-ALPHA-8821"
        let neighborMeta = FrameMetaSubset(metadata: Metadata([
            "wax.memory_type": "decision",
            "wax.durability": "durable",
            "wax.repo": "Wax",
            "wax.project": "Wax",
        ]))

        var neighborIDs: [UInt64] = []
        neighborIDs.reserveCapacity(6)
        for index in 0..<6 {
            let body =
                "Grok Wax MCP stress canary neighbor \(index) records durable canary alpha stress notes without the unique hyphenated identifier."
            let neighborID = try await wax.put(Data(body.utf8), options: neighborMeta)
            neighborIDs.append(neighborID)
        }

        let exactBody = "Durable canary frame records unique token \(token) for retrieval."
        let exactID = try await wax.put(
            Data(exactBody.utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "note",
                "wax.durability": "durable",
                "wax.repo": "other-repo",
                "wax.project": "other-project",
            ]))
        )

        var vectorHits = neighborIDs.enumerated().map { index, frameId in
            (frameId: frameId, score: Float(0.99) - Float(index) * 0.01)
        }
        vectorHits.append((frameId: exactID, score: 0.01))

        let response = try await wax.search(
            SearchRequest(
                query: token,
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .vectorOnly,
                topK: 5,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: DeterministicVectorResultsEngine(
                    dimensions: 4,
                    results: vectorHits
                ),
                structuredEngine: nil
            )
        )

        #expect(response.results.count <= 5)
        #expect(response.results.first?.frameId != exactID)
        #expect(!response.results.contains { $0.frameId == exactID })
        #expect(response.results.map(\.frameId) == Array(neighborIDs.prefix(5)))

        try await wax.close()
    }
}

/// Unpunctuated `OR` is a Ranking token, not an FTS boolean. AND of both
/// terms misses disjoint frames; OR fallback then publishes a 1-of-2 score.
@Test func unpunctuatedBooleanWordsAreLiteralsNotFTSOperators() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let catsOnly = try await wax.put(Data("only cats live here".utf8))
        try await text.index(frameId: catsOnly, text: "only cats live here")
        let dogsOnly = try await wax.put(Data("only dogs live here".utf8))
        try await text.index(frameId: dogsOnly, text: "only dogs live here")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(query: "cats OR dogs", mode: .textOnly, topK: 10, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        )
        let catsHit = try #require(response.results.first { $0.frameId == catsOnly })
        let dogsHit = try #require(response.results.first { $0.frameId == dogsOnly })
        #expect(catsHit.score <= 0.5)
        #expect(dogsHit.score <= 0.5)

        try await wax.close()
    }
}

@Test func textOnlySearchSkipsMatchWhenPlanIsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let indexed = try await wax.put(Data("the and or not near filler".utf8))
        try await text.index(frameId: indexed, text: "the and or not near filler")
        try await text.commit()

        let stopwordOnly = try await wax.search(
            SearchRequest(query: "the and or", mode: .textOnly, topK: 10, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        )
        #expect(stopwordOnly.results.isEmpty)

        let operatorOnly = try await wax.search(
            SearchRequest(query: "NOT NEAR", mode: .textOnly, topK: 10, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        )
        #expect(operatorOnly.results.isEmpty)

        try await wax.close()
    }
}

@Test func hybridSearchFusesTextVectorTimelineAndStructuredLanes() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        let session = try await wax.openSession(.readWrite(.fail), config: config)

        let timelineOnly = try await session.put(
            Data("unrelated old filler note".utf8),
            options: FrameMetaSubset(searchText: "unrelated old filler note"),
            timestampMs: 1_000
        )
        try await session.indexText(frameId: timelineOnly, text: "unrelated old filler note")

        let evidence = try await session.put(
            Data("Structured evidence payload without the alias.".utf8),
            options: FrameMetaSubset(searchText: "Structured evidence payload"),
            timestampMs: 2_000
        )
        try await session.indexText(frameId: evidence, text: "Structured evidence payload")

        let vectorOnly = try await session.put(
            Data("unrelated vector neighbor filler".utf8),
            options: FrameMetaSubset(searchText: "unrelated vector neighbor filler"),
            timestampMs: 3_000
        )
        try await session.indexText(frameId: vectorOnly, text: "unrelated vector neighbor filler")

        let textHit = try await session.put(
            Data("F027Alice last seen at the dock".utf8),
            options: FrameMetaSubset(searchText: "F027Alice last seen at the dock"),
            timestampMs: 4_000
        )
        try await session.indexText(frameId: textHit, text: "F027Alice last seen at the dock")

        _ = try await session.upsertEntity(
            key: EntityKey("person:f027-alice"),
            kind: "person",
            aliases: ["F027Alice"],
            nowMs: 5_000
        )
        _ = try await session.assertFact(
            subject: EntityKey("person:f027-alice"),
            predicate: PredicateKey("status"),
            object: .string("active"),
            valid: StructuredTimeRange(fromMs: 0),
            system: StructuredTimeRange(fromMs: 5_000),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: evidence,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: 1,
                    assertedAtMs: 5_000
                ),
            ]
        )
        try await session.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "when was F027Alice last seen",
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.5),
                topK: 10,
nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                enableRankingDiagnostics: true,
                rankingDiagnosticsTopK: 10
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: DeterministicVectorResultsEngine(
                    dimensions: 4,
                    results: [(frameId: vectorOnly, score: 0.99)]
                ),
                structuredEngine: nil
            )
        )

        let byID = Dictionary(uniqueKeysWithValues: response.results.map { ($0.frameId, $0) })
        let textResult = try #require(byID[textHit])
        let vectorResult = try #require(byID[vectorOnly])
        let evidenceResult = try #require(byID[evidence])
        let timelineResult = try #require(byID[timelineOnly])
        #expect(textResult.sources.contains(.text))
        #expect(vectorResult.sources.contains(.vector))
        #expect(evidenceResult.sources.contains(.structured))
        #expect(timelineResult.sources.contains(.timeline))
        #expect(timelineResult.sources.contains(.text) == false)

        let laneSources = Set(
            response.results.compactMap(\.rankingDiagnostics).flatMap(\.laneContributions).map(\.source)
        )
        #expect(laneSources.contains(.text))
        #expect(laneSources.contains(.vector))
        #expect(laneSources.contains(.timeline))
        #expect(laneSources.contains(.structured))

        for (previous, next) in zip(response.results, response.results.dropFirst()) {
            #expect(previous.score >= next.score)
        }

        await session.close()
        try await wax.close()
    }
}

// MARK: - T3 clock-anchor determinism (AC-003)

@Test func memorySemanticsClassificationChangesWithAnchorAndIsStablePerAnchor() {
    let baseMs: Int64 = 1_700_000_000_000
    let dayMs: Int64 = 24 * 60 * 60 * 1000
    var metadata: [String: String] = [
        MemoryMetadataKeys.type: MemoryType.taskState.rawValue,
        MemoryMetadataKeys.durability: MemoryDurability.working.rawValue,
    ]
    metadata[MemoryMetadataKeys.createdAtMs] = String(baseMs)
    metadata[MemoryMetadataKeys.expiresAtMs] = String(baseMs + 10 * dayMs)

    // Different anchors must classify the same content differently, predictably.
    let freshInfo = MemorySemantics.parse(metadata: metadata, nowMs: baseMs + dayMs)
    #expect(freshInfo.isExpired == false)
    let staleInfo = MemorySemantics.parse(metadata: metadata, nowMs: baseMs + 20 * dayMs)
    #expect(staleInfo.isExpired == true)

    let freshReasons = MemorySemantics.rankingReasons(metadata: metadata, scope: nil, nowMs: baseMs + dayMs)
    #expect(freshReasons.reasons.contains("recent task state"))
    #expect(!freshReasons.reasons.contains("expired memory"))
    let staleReasons = MemorySemantics.rankingReasons(metadata: metadata, scope: nil, nowMs: baseMs + 20 * dayMs)
    #expect(staleReasons.reasons.contains("expired memory"))

    // The same anchor must produce identical results on repeated calls.
    for _ in 0..<3 {
        let repeatFresh = MemorySemantics.rankingReasons(metadata: metadata, scope: nil, nowMs: baseMs + dayMs)
        #expect(repeatFresh.adjustment == freshReasons.adjustment)
        #expect(repeatFresh.reasons == freshReasons.reasons)
        let repeatStale = MemorySemantics.rankingReasons(metadata: metadata, scope: nil, nowMs: baseMs + 20 * dayMs)
        #expect(repeatStale.adjustment == staleReasons.adjustment)
        #expect(repeatStale.reasons == staleReasons.reasons)
    }
}

@Test func unifiedSearchRankingIsByteIdenticalUnderFixedAnchorAndShiftsWithNewAnchor() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        let session = try await wax.openSession(.readWrite(.fail), config: config)

        let baseMs: Int64 = 1_700_000_000_000
        let dayMs: Int64 = 24 * 60 * 60 * 1000

        // Durable decision: strong positive semantic adjustment at both anchors.
        let decisionFrame = try await session.put(
            Data("anchor determinism alpha release decision".utf8),
            options: FrameMetaSubset(
                searchText: "anchor determinism alpha release decision",
                metadata: Metadata([
                    MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                ])
            ),
            timestampMs: baseMs
        )
        try await session.indexText(frameId: decisionFrame, text: "anchor determinism alpha release decision")

        // Short-lived ephemeral note: alive at anchor A, expired by anchor B.
        let ephemeralFrame = try await session.put(
            Data("anchor determinism beta scratch note".utf8),
            options: FrameMetaSubset(
                searchText: "anchor determinism beta scratch note",
                metadata: Metadata([
                    MemoryMetadataKeys.type: MemoryType.note.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.ephemeral.rawValue,
                    MemoryMetadataKeys.createdAtMs: String(baseMs),
                    MemoryMetadataKeys.expiresAtMs: String(baseMs + 10 * dayMs),
                ])
            ),
            timestampMs: baseMs
        )
        try await session.indexText(frameId: ephemeralFrame, text: "anchor determinism beta scratch note")
        try await session.commit()

        let anchorA = baseMs + dayMs
        let anchorB = baseMs + 30 * dayMs

        func request(nowMs: Int64) -> SearchRequest {
            SearchRequest(query: "anchor determinism", mode: .textOnly, topK: 10, nowMs: nowMs)
        }

        let firstA = try await session.search(request(nowMs: anchorA))
        let secondA = try await session.search(request(nowMs: anchorA))
        // Byte-identical ranking under a repeated fixed anchor.
        #expect(firstA.results.map(\.frameId) == secondA.results.map(\.frameId))
        #expect(firstA.results.map(\.score) == secondA.results.map(\.score))
        #expect(firstA.results.map(\.explanations) == secondA.results.map(\.explanations))

        // At anchor A both documents are live; the durable decision outranks the ephemeral note.
        #expect(firstA.results.map(\.frameId).prefix(2).contains(decisionFrame))
        #expect(firstA.results.map(\.frameId).prefix(2).contains(ephemeralFrame))
        if let decisionIndex = firstA.results.firstIndex(where: { $0.frameId == decisionFrame }),
           let ephemeralIndex = firstA.results.firstIndex(where: { $0.frameId == ephemeralFrame }) {
            #expect(decisionIndex < ephemeralIndex)
            #expect(firstA.results[decisionIndex].explanations.contains("decision memory"))
            #expect(firstA.results[decisionIndex].explanations.contains("durable"))
        } else {
            Issue.record("expected both frames to be returned at anchor A")
        }

        // At anchor B the ephemeral note has expired and must drop out entirely,
        // while the decision frame remains.
        let firstB = try await session.search(request(nowMs: anchorB))
        let secondB = try await session.search(request(nowMs: anchorB))
        #expect(firstB.results.map(\.frameId) == secondB.results.map(\.frameId))
        #expect(firstB.results.map(\.score) == secondB.results.map(\.score))
        #expect(firstB.results.map(\.explanations) == secondB.results.map(\.explanations))
        #expect(firstB.results.map(\.frameId) == [decisionFrame])
        #expect(firstB.results.first?.explanations.contains("expired memory") != true)

        await session.close()
        try await wax.close()
    }
}
