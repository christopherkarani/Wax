import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

/// Operator case: multi-token text query whose AND pass misses, then OR-fallback
/// matches a common token like "drop" and used to publish a perfect 1.0 score.
@Test func textSearchMultiTokenORFallbackDoesNotScoreUnrelatedDropHitAsPerfect() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Fillers keep "drop" rare so FTS BM25 IDF is nonzero. A one-doc index
        // makes every term corpus-wide and collapses the published score to 0.
        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "adversarial-fp.md stash-drop deny",
                mode: .textOnly,
                topK: 10,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        let dropHit = try #require(response.results.first { $0.frameId == dropOnly })
        // Operator query tokenizes to 6 FTS tokens; 1-of-N scale is 1/6.
        // Saturated BM25 publishes Float(1) as ~0.99999994.
        #expect(dropHit.score <= (1.0 / 6.0) + 0.02)
        #expect(dropHit.score > 0)

        try await wax.close()
    }
}

@Test func textSearchANDMatchRanksAboveORFallbackOnlyDropHit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let andMatchText = "policy for adversarial-fp.md stash-drop deny on redteam fixtures"
        let andMatch = try await wax.put(Data(andMatchText.utf8))
        try await text.index(frameId: andMatch, text: andMatchText)

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "adversarial-fp.md stash-drop deny",
                mode: .textOnly,
                topK: 10,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        let andHit = try #require(response.results.first { $0.frameId == andMatch })
        let dropHit = try #require(response.results.first { $0.frameId == dropOnly })
        #expect(response.results.first?.frameId == andMatch)
        #expect(andHit.score > dropHit.score)
        #expect(dropHit.score <= (1.0 / 6.0) + 0.02)

        try await wax.close()
    }
}

@Test func textSearchTwoTokenORFallbackScalesToHalf() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "alpha drop",
                mode: .textOnly,
                topK: 10,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        let dropHit = try #require(response.results.first { $0.frameId == dropOnly })
        #expect(dropHit.score <= 0.5 + 0.02)
        #expect(abs(dropHit.score - 0.5) < 0.1)

        try await wax.close()
    }
}

@Test func textSearchThreeTokenORFallbackScalesToOneThird() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "alpha beta drop",
                mode: .textOnly,
                topK: 10,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        let dropHit = try #require(response.results.first { $0.frameId == dropOnly })
        #expect(dropHit.score <= (1.0 / 3.0) + 0.02)
        #expect(abs(dropHit.score - (1.0 / 3.0)) < 0.1)

        try await wax.close()
    }
}

@Test func textSearchSingleTokenCanaryStaysUnscaled() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let canary = try await wax.put(Data("unique lexical canary 7f3a91".utf8))
        try await text.index(frameId: canary, text: "unique lexical canary 7f3a91")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "7f3a91",
                mode: .textOnly,
                topK: 10,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )

        let hit = try #require(response.results.first { $0.frameId == canary })
        #expect(hit.score >= 0.9)

        try await wax.close()
    }
}

@Test func hybridDefaultDoesNotCrownORFallbackOnlyDropAsRank1() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Lower frame id so equal-weight RRF tie-breaks to the vector neighbor
        // unless the exclusive-text floor incorrectly lifts the drop hit.
        let neighbor = try await wax.put(Data("unrelated vector neighbor filler".utf8))

        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "adversarial-fp.md stash-drop deny",
                embedding: [1.0, 0.0, 0.0, 0.0],
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.5),
                topK: 10,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000)
            ),
            engineOverrides: UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: InjectedHybridVectorEngine(
                    dimensions: 4,
                    results: [(frameId: neighbor, score: 0.95)]
                ),
                structuredEngine: nil
            )
        )

        #expect(response.results.first?.frameId != dropOnly)
        #expect(response.results.first?.frameId == neighbor)

        try await wax.close()
    }
}

private actor InjectedHybridVectorEngine: VectorSearchEngine {
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
