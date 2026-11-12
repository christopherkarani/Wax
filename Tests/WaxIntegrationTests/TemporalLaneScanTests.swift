import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

private actor FixedHitVectorEngine: VectorSearchEngine {
    let dimensions = 2
    let hits: [(frameId: UInt64, score: Float)]
    init(hits: [(frameId: UInt64, score: Float)]) { self.hits = hits }
    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] { hits }
    func add(frameId: UInt64, vector: [Float]) async throws {}
    func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {}
    func remove(frameId: UInt64) async throws {}
    func stageForCommit(into wax: Wax) async throws {}
}

/// A query the classifier calls temporal ("when ...") makes hybrid search walk the whole
/// frame list for a recency lane. Only hybrid fusion reads that lane, so single-lane searches
/// must not pay for the walk: at 100k frames it was most of a temporal query's latency.
@Suite
struct TemporalLaneScanTests {
    private static let temporalQuery = "when was the earthquake in san francisco"

    @Test func vectorOnlyTemporalSearchDoesNotScanTheTimeline() async throws {
        try await Self.withStore { wax, frameID in
            #expect(RuleBasedQueryClassifier.classify(Self.temporalQuery) == .temporal)
            let request = try SearchRequest(query: Self.temporalQuery, lane: .vectorOnly(embedding: [1, 0]), topK: 4)
            let before = await wax.timelineScansForTesting()
            let response = try await wax.search(request, engineOverrides: .init(
                vectorEngine: FixedHitVectorEngine(hits: [(frameID, 0.9)])
            ))
            #expect(response.results.map(\.frameId) == [frameID])
            #expect(await wax.timelineScansForTesting() == before)
        }
    }

    @Test func textOnlyTemporalSearchDoesNotScanTheTimeline() async throws {
        try await Self.withStore { wax, frameID in
            let request = try SearchRequest(query: Self.temporalQuery, lane: .textOnly, topK: 4)
            let before = await wax.timelineScansForTesting()
            let response = try await wax.search(request)
            #expect(response.results.first?.frameId == frameID)
            #expect(await wax.timelineScansForTesting() == before)
        }
    }

    /// Control: hybrid fusion still reads the recency lane, so the counter does move.
    @Test func hybridTemporalSearchStillScansTheTimeline() async throws {
        try await Self.withStore { wax, frameID in
            let request = try SearchRequest(
                query: Self.temporalQuery,
                lane: .hybrid(alpha: 0.5, embedding: [1, 0]),
                topK: 4
            )
            let before = await wax.timelineScansForTesting()
            let response = try await wax.search(request, engineOverrides: .init(
                vectorEngine: FixedHitVectorEngine(hits: [(frameID, 0.9)])
            ))
            #expect(response.results.first?.sources.contains(.timeline) == true)
            #expect(await wax.timelineScansForTesting() == before + 1)
        }
    }

    private static func withStore(_ body: (Wax, UInt64) async throws -> Void) async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            do {
                let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
                for index in 0..<8 {
                    let filler = "unrelated widget corpus filler \(index) about release notes"
                    try await text.indexText(frameId: try await wax.put(Data(filler.utf8)), text: filler)
                }
                let passage = "The earthquake hit San Francisco during the World Series"
                let frameID = try await wax.put(Data(passage.utf8))
                try await text.indexText(frameId: frameID, text: passage)
                try await text.commit()
                try await body(wax, frameID)
                try await wax.close()
            } catch {
                try? await wax.close()
                throw error
            }
        }
    }
}
