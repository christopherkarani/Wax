import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

private actor DiagnosticVectorEngine: VectorSearchEngine {
    let dimensions = 2
    let hang: Bool
    let hits: [(frameId: UInt64, score: Float)]
    init(hang: Bool, hits: [(frameId: UInt64, score: Float)] = []) {
        self.hang = hang
        self.hits = hits
    }
    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        // Suspends until AsyncTimeout cancels the lane, so it cannot finish inside any budget.
        if hang { try await Task.sleep(for: .seconds(86_400)) }
        return hits
    }
    func add(frameId: UInt64, vector: [Float]) async throws {}
    func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {}
    func remove(frameId: UInt64) async throws {}
    func stageForCommit(into wax: Wax) async throws {}
}

@Suite
struct VectorLaneDiagnosticsTests {
    @Test func singleVectorLanePreservesSimilarityAcrossIndependentSearches() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            do {
                let frameID = try await wax.put(Data("A candidate document with no lexical query overlap".utf8))
                let request = try SearchRequest(
                    query: "vehicle stopping system",
                    lane: .hybrid(alpha: 0.5, embedding: [1, 0]),
                    topK: 4
                )
                let relevant = try await wax.search(request, engineOverrides: .init(
                    vectorEngine: DiagnosticVectorEngine(hang: false, hits: [(frameID, 0.95)])
                ))
                let irrelevant = try await wax.search(request, engineOverrides: .init(
                    vectorEngine: DiagnosticVectorEngine(hang: false, hits: [(frameID, 0.20)])
                ))
                let relevantHit = try #require(relevant.results.first)
                let irrelevantHit = try #require(irrelevant.results.first)
                #expect(relevantHit.sources == [.vector])
                #expect(irrelevantHit.sources == [.vector])
                #expect(relevantHit.score > irrelevantHit.score + 0.2)
                try await wax.close()
            } catch {
                try? await wax.close()
                throw error
            }
        }
    }

    @Test func contextBuilderReportsVectorTimeoutAsTextFallback() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            do {
                let context = try await FastRAGContextBuilder().build(
                    query: "memory reliability", embedding: [1, 0],
                    vectorSearchTimeout: .milliseconds(25), wax: wax,
                    engineOverrides: .init(vectorEngine: DiagnosticVectorEngine(hang: true)),
                    config: FastRAGConfig(deterministicNowMs: 1_700_000_000_000)
                )
                #expect(context.diagnostics?.effectiveMode == .textOnly)
                #expect(context.diagnostics?.queryEmbeddingState == .available)
                try await wax.close()
            } catch {
                try? await wax.close()
                throw error
            }
        }
    }

    @Test(arguments: [[Float](), nil])
    func contextBuilderReportsTextEffectiveWhenHybridHasNoEmbedding(embedding: [Float]?) async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            do {
                let context = try await FastRAGContextBuilder().build(
                    query: "memory reliability",
                    embedding: embedding,
                    wax: wax,
                    config: FastRAGConfig(
                        searchMode: .hybrid(alpha: 0.5),
                        deterministicNowMs: 1_700_000_000_000
                    )
                )
                #expect(context.diagnostics?.requestedMode == .hybrid(alpha: 0.5))
                #expect(context.diagnostics?.effectiveMode == .textOnly)
                #expect(context.diagnostics?.queryEmbeddingState == .notRequested)
                try await wax.close()
            } catch {
                try? await wax.close()
                throw error
            }
        }
    }

    // The time limit fails a regression instead of the 1h empty-lane budget.
    @Test(.timeLimit(.minutes(2)), arguments: [true, false])
    func distinguishesVectorTimeoutFromSuccessfulEmptyLane(hang: Bool) async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            do {
                // Only the hang case may time out: it never completes, so a tight
                // budget always fires. The empty lane gets an hour, far past any
                // scheduler stall on a loaded runner, so it can only finish first.
                let response = try await wax.search(
                    SearchRequest(
                        query: "memory reliability",
                        lane: .hybrid(alpha: 0.5, embedding: [1, 0]),
                        vectorSearchTimeout: hang ? .milliseconds(40) : .seconds(3_600),
                        topK: 4
                    ),
                    engineOverrides: .init(vectorEngine: DiagnosticVectorEngine(hang: hang))
                )
                if hang {
                    #expect(response.vectorSearchTimedOut)
                } else {
                    #expect(!response.vectorSearchTimedOut)
                }
                try await wax.close()
            } catch {
                try? await wax.close()
                throw error
            }
        }
    }
}
