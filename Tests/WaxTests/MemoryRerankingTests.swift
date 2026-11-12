import Foundation
import Testing
@testable import Wax
import WaxTestSupport

/// Scores each document by a caller-supplied rule and records every call.
private actor RecordingReranker: RerankingProvider {
    private let rule: @Sendable (String) -> Float
    private(set) var calls: [(query: String, documents: [String])] = []

    init(rule: @escaping @Sendable (String) -> Float) {
        self.rule = rule
    }

    func scores(query: String, documents: [String]) async throws -> [Float] {
        calls.append((query, documents))
        return documents.map(rule)
    }
}

/// Returns a fixed reply, whatever it is asked.
private struct FixedReplyReranker: RerankingProvider {
    let reply: @Sendable (Int) throws -> [Float]

    func scores(query: String, documents: [String]) async throws -> [Float] {
        try reply(documents.count)
    }
}

private struct RerankFailure: Error, Equatable {}

private func withTextStore<T>(
    reranking: Memory.RerankingSource?,
    documents: [String],
    _ body: (Memory) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-rerank-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Memory.Config.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    if let reranking {
        config.reranking = reranking
    }
    let memory = try await Memory(at: url, config: config)
    do {
        for (index, text) in documents.enumerated() {
            try await memory.save(text, metadata: ["doc_id": "d\(index)"])
        }
        try await memory.flush()
        let result = try await body(memory)
        try await memory.close()
        return result
    } catch {
        try? await memory.close()
        throw error
    }
}

private let textOnly = Memory.SearchOptions(topK: 10, mode: .textOnly, inferTimeRange: false)

/// Distinct documents that all match "apple"; the text lane ranks them by BM25.
private let appleDocuments = [
    "apple apple apple orchard harvest",
    "apple apple pie recipe",
    "apple tree in the garden",
    "an apple a day keeps the doctor away, says the zebra",
]

private func docIDs(_ results: Memory.Results) -> [String] {
    results.items.compactMap { $0.metadata["doc_id"] }
}

@Suite struct MemoryRerankingTests {
    @Test func rerankingIsDisabledByDefault() {
        guard case .disabled = Memory.Config.default.reranking else {
            Issue.record("Memory.Config.default.reranking should be .disabled")
            return
        }
    }

    @Test func disabledRerankingLeavesResultsUnchanged() async throws {
        let baseline = try await withTextStore(reranking: nil, documents: appleDocuments) {
            try await $0.search("apple", options: textOnly)
        }
        let disabled = try await withTextStore(reranking: .disabled, documents: appleDocuments) {
            try await $0.search("apple", options: textOnly)
        }
        #expect(docIDs(baseline).count == appleDocuments.count)
        #expect(docIDs(disabled) == docIDs(baseline))
        #expect(disabled.items.map(\.score) == baseline.items.map(\.score))
    }

    @Test func rerankerOrderPutsTheHighestScoredCandidateFirst() async throws {
        let reranker = RecordingReranker { $0.contains("zebra") ? 10 : 0 }
        let options = RerankingOptions(candidateCount: 20, fusion: .rerankerOrder)
        let reranked = try await withTextStore(reranking: .custom(reranker, options), documents: appleDocuments) {
            try await $0.search("apple", options: textOnly)
        }
        #expect(docIDs(reranked).first == "d3")
        // Ties keep the retrieval order, so the other three stay in BM25 order.
        let plain = try await withTextStore(reranking: nil, documents: appleDocuments) {
            try await $0.search("apple", options: textOnly)
        }
        #expect(Array(docIDs(reranked).dropFirst()) == docIDs(plain).filter { $0 != "d3" })
        let calls = await reranker.calls
        #expect(calls.count == 1)
        #expect(calls.first?.query == "apple")
    }

    @Test func rerankerSeesTheFullFrameTextNotThePreview() async throws {
        let long = "apple " + String(repeating: "filler words that pad the passage ", count: 30) + "ENDMARKER"
        let reranker = RecordingReranker { _ in 0 }
        _ = try await withTextStore(
            reranking: .custom(reranker, RerankingOptions(candidateCount: 5, fusion: .rerankerOrder)),
            documents: [long]
        ) {
            try await $0.search("apple", options: textOnly)
        }
        let documents = await reranker.calls.first?.documents ?? []
        #expect(documents == [long])
    }

    @Test func candidateCountBoundsTheRerankedWindow() async throws {
        // Only the top 2 are reranked: the zebra document at retrieval rank 4 is never seen.
        let reranker = RecordingReranker { $0.contains("zebra") ? 10 : ($0.contains("tree") ? 5 : 0) }
        let options = RerankingOptions(candidateCount: 2, fusion: .rerankerOrder)
        let plain = try await withTextStore(reranking: nil, documents: appleDocuments) {
            try await $0.search("apple", options: textOnly)
        }
        let reranked = try await withTextStore(reranking: .custom(reranker, options), documents: appleDocuments) {
            try await $0.search("apple", options: textOnly)
        }
        let calls = await reranker.calls
        #expect(calls.first?.documents.count == 2)
        // Below the window the retrieval order stands.
        #expect(Array(docIDs(reranked).dropFirst(2)) == Array(docIDs(plain).dropFirst(2)))
        #expect(Set(docIDs(reranked).prefix(2)) == Set(docIDs(plain).prefix(2)))
    }

    @Test func rerankingCanPromoteACandidateFromBeyondTopK() async throws {
        let reranker = RecordingReranker { $0.contains("zebra") ? 10 : 0 }
        let options = RerankingOptions(candidateCount: 10, fusion: .rerankerOrder)
        let results = try await withTextStore(reranking: .custom(reranker, options), documents: appleDocuments) {
            try await $0.search("apple", options: Memory.SearchOptions(topK: 1, mode: .textOnly, inferTimeRange: false))
        }
        #expect(docIDs(results) == ["d3"])
        #expect(await reranker.calls.first?.documents.count == appleDocuments.count)
    }

    @Test func candidateCountIsClampedToItsRange() {
        #expect(RerankingOptions(candidateCount: 0).candidateCount == RerankingOptions.candidateCountRange.lowerBound)
        #expect(RerankingOptions(candidateCount: -5).candidateCount == 1)
        #expect(RerankingOptions(candidateCount: 10_000).candidateCount == RerankingOptions.candidateCountRange.upperBound)
        #expect(RerankingOptions(fusion: .reciprocalRank(k: -3)).fusion == .reciprocalRank(k: 0))
    }

    @Test func defaultsMatchTheMeasuredConfiguration() {
        #expect(RerankingOptions.default.candidateCount == 20)
        #expect(RerankingOptions.default.fusion == .reciprocalRank(k: 10))
    }

    @Test func noResultsMeansNoRerankerCall() async throws {
        let reranker = RecordingReranker { _ in 1 }
        let results = try await withTextStore(
            reranking: .custom(reranker, .default),
            documents: appleDocuments
        ) {
            try await $0.search("nonexistentterm", options: textOnly)
        }
        #expect(results.items.isEmpty)
        #expect(await reranker.calls.isEmpty)
    }

    @Test func singleResultIsScoredAndReturned() async throws {
        let reranker = RecordingReranker { _ in 1 }
        let results = try await withTextStore(reranking: .custom(reranker, .default), documents: ["kiwi fruit"]) {
            try await $0.search("kiwi", options: textOnly)
        }
        #expect(docIDs(results) == ["d0"])
    }

    @Test func rerankerErrorsPropagateFromSearch() async throws {
        let reranker = FixedReplyReranker { _ in throw RerankFailure() }
        await #expect(throws: RerankFailure.self) {
            try await withTextStore(reranking: .custom(reranker, .default), documents: appleDocuments) {
                try await $0.search("apple", options: textOnly)
            }
        }
    }

    @Test func wrongScoreCountThrows() async throws {
        let reranker = FixedReplyReranker { count in Array(repeating: 1, count: count + 1) }
        await #expect(throws: WaxError.self) {
            try await withTextStore(reranking: .custom(reranker, .default), documents: appleDocuments) {
                try await $0.search("apple", options: textOnly)
            }
        }
    }

    @Test func nonFiniteScoresThrow() async throws {
        let reranker = FixedReplyReranker { count in Array(repeating: .nan, count: count) }
        await #expect(throws: WaxError.self) {
            try await withTextStore(reranking: .custom(reranker, .default), documents: appleDocuments) {
                try await $0.search("apple", options: textOnly)
            }
        }
    }

    @Test func builtInRerankerWithoutItsTraitFailsAtOpen() async throws {
        #if !MiniLMReranker
        await #expect(throws: BuiltInRerankerError.unavailable(.msMarcoMiniLM)) {
            try await withTextStore(reranking: .builtIn(.msMarcoMiniLM), documents: []) { _ in () }
        }
        #endif
    }
}

@Suite struct RerankFusionTests {
    @Test func rerankerOrderSortsByScoreAndKeepsRetrievalOrderOnTies() {
        let order = RerankStage.fusedOrder(scores: [1, 3, 3, 0], fusion: .rerankerOrder)
        #expect(order == [1, 2, 0, 3])
    }

    @Test func reciprocalRankFusesRetrievalAndRerankerRanks() {
        // Reranker ranks: index 3 -> 1, 2 -> 2, 1 -> 3, 0 -> 4. With k = 10 each candidate
        // scores 1/(10 + retrievalRank) + 1/(10 + rerankerRank); 0 and 3 tie at 1/11 + 1/14,
        // as do 1 and 2 at 1/12 + 1/13. Ties keep the retrieval order.
        let order = RerankStage.fusedOrder(scores: [0, 1, 2, 3], fusion: .reciprocalRank(k: 10))
        #expect(order == [0, 3, 1, 2])
    }

    @Test func reciprocalRankLetsAStrongRerankerScoreMoveACandidateUp() {
        // Retrieval ranks 1..5; the reranker puts index 4 first and keeps the rest in order.
        let order = RerankStage.fusedOrder(scores: [4, 3, 2, 1, 9], fusion: .reciprocalRank(k: 1))
        // index 4: 1/(1+5) + 1/(1+1) = 0.667; index 0: 1/2 + 1/3 = 0.833; index 1: 1/3 + 1/4 = 0.583
        #expect(order == [0, 4, 1, 2, 3])
    }

    @Test func emptyAndSingleCandidates() {
        #expect(RerankStage.fusedOrder(scores: [], fusion: .rerankerOrder).isEmpty)
        #expect(RerankStage.fusedOrder(scores: [5], fusion: .reciprocalRank(k: 60)) == [0])
    }
}
