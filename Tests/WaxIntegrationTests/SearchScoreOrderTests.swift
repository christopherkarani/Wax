import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

/// Injected lane that can return scores out of published order.
private actor InjectedVectorScoreEngine: VectorSearchEngine {
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

@Test func sessionVectorReportedScoresDescendSo070CannotRankAbove078() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let weaker = try await wax.put(Data("weaker session vector neighbor".utf8))
        let stronger = try await wax.put(Data("stronger session vector neighbor".utf8))

        let response = try await wax.searchWithEngineStore(
            SearchRequest(
                embedding: [1.0, 0.0, 0.0, 0.0],
                mode: .vectorOnly,
                topK: 2,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            engines: UnifiedSearchEngines(
                textEngine: nil,
                vectorEngine: InjectedVectorScoreEngine(
                    dimensions: 4,
                    results: [
                        (frameId: weaker, score: 0.70),
                        (frameId: stronger, score: 0.78),
                    ]
                ),
                structuredEngine: nil
            )
        )

        #expect(response.results.map(\.frameId) == [stronger, weaker])
        #expect(response.results.map(\.score) == [0.78, 0.70])
        for (previous, next) in zip(response.results, response.results.dropFirst()) {
            #expect(previous.score >= next.score)
        }

        try await wax.close()
    }
}

@Test func hybridSearchReportedScoresDescendAfterFusion() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let canary = try await wax.put(Data("unique lexical canary 7f3a91".utf8))
        try await text.index(frameId: canary, text: "unique lexical canary 7f3a91")
        let neighbor = try await wax.put(Data("unrelated vector neighbor filler".utf8))
        try await text.commit()

        let response = try await wax.searchWithEngineStore(
            SearchRequest(
                query: "7f3a91",
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            engines: UnifiedSearchEngines(
                textEngine: nil,
                vectorEngine: InjectedVectorScoreEngine(
                    dimensions: 4,
                    results: [(frameId: neighbor, score: 0.95)]
                ),
                structuredEngine: nil
            )
        )

        #expect(response.results.first?.frameId == canary)
        for (previous, next) in zip(response.results, response.results.dropFirst()) {
            #expect(previous.score >= next.score)
        }

        try await wax.close()
    }
}

@Test func sessionVectorSemanticRerankPublishesTheScoreItRanksOn() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let weaker = try await wax.put(
            Data("session decision memory".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "decision",
                "wax.durability": "durable",
                "wax.repo": "Wax",
                "wax.project": "Wax",
            ]))
        )
        let stronger = try await wax.put(
            Data("session note memory".utf8),
            options: FrameMetaSubset(metadata: Metadata([
                "wax.memory_type": "note",
                "wax.durability": "working",
                "wax.repo": "other-repo",
                "wax.project": "other-repo",
            ]))
        )

        let response = try await wax.searchWithEngineStore(
            SearchRequest(
                embedding: [1.0, 0.0, 0.0, 0.0],
                mode: .vectorOnly,
                topK: 2,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                scopeContext: MemoryScopeContext(repoName: "Wax", projectName: "Wax")
            ),
            engines: UnifiedSearchEngines(
                textEngine: nil,
                vectorEngine: InjectedVectorScoreEngine(
                    dimensions: 4,
                    results: [
                        (frameId: weaker, score: 0.70),
                        (frameId: stronger, score: 0.78),
                    ]
                ),
                structuredEngine: nil
            )
        )

        #expect(response.results.count == 2)
        for (previous, next) in zip(response.results, response.results.dropFirst()) {
            #expect(previous.score >= next.score)
        }
        let top = try #require(response.results.first)
        if top.frameId == weaker {
            // Semantic lift may rank the 0.70 decision first, but then the
            // published number must be the rank score — not 0.70 above 0.78.
            #expect(top.score > 0.78)
        } else {
            #expect(top.frameId == stronger)
            #expect(top.score >= 0.78)
        }

        try await wax.close()
    }
}
