import Foundation
import Testing
@testable import Wax
import WaxTestSupport

/// Scores documents containing `marker` above the rest and counts its calls.
private actor MarkerReranker: RerankingProvider {
    let marker: String
    private(set) var callCount = 0

    init(marker: String) {
        self.marker = marker
    }

    func scores(query: String, documents: [String]) async throws -> [Float] {
        callCount += 1
        return documents.map { $0.contains(marker) ? 10 : 0 }
    }
}

private struct FailingReranker: RerankingProvider {
    struct Failure: Error {}

    func scores(query: String, documents: [String]) async throws -> [Float] {
        throw Failure()
    }
}

/// Distinct documents that all match "apple"; the zebra one ranks last by BM25.
private let appleDocuments = [
    "apple apple apple orchard harvest",
    "apple apple pie recipe",
    "apple tree in the garden",
    "an apple a day keeps the doctor away, says the zebra",
]

private func withOrchestrator<T>(
    reranking: RerankStage?,
    _ body: (MemoryOrchestrator) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-auto-rerank-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = OrchestratorConfig.default
    config.requireOnDeviceProviders = false
    config.enableStructuredMemory = false
    config.reranking = reranking
    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: DeterministicTextEmbedder())
    do {
        for (index, text) in appleDocuments.enumerated() {
            _ = try await memory.remember(text, metadata: ["doc_id": "d\(index)"])
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

private func docIDs(_ context: RAGContext) -> [String] {
    context.items.compactMap { $0.metadata["doc_id"] }
}

private func automaticStage(_ provider: any RerankingProvider) async throws -> RerankStage? {
    try await BuiltInRerankerCompiler.stage(for: .automatic, automaticProvider: { provider })
}

@Suite struct AutomaticRerankingTests {
    @Test func rerankingIsAutomaticByDefault() {
        guard case .automatic = Memory.Config.default.reranking else {
            Issue.record("Memory.Config.default.reranking should be .automatic")
            return
        }
    }

    @Test func automaticWithoutABuiltInRerankerDoesNotRerank() async throws {
        let stage = try await BuiltInRerankerCompiler.stage(for: .automatic, automaticProvider: { nil })
        #expect(stage == nil)
    }

    @Test func automaticReranksTextAndHybridButNotVectorOnly() async throws {
        let stage = try #require(try await automaticStage(MarkerReranker(marker: "zebra")))
        #expect(stage.applies(to: .textOnly))
        #expect(stage.applies(to: .hybrid(alpha: 0.4)))
        #expect(!stage.applies(to: .vectorOnly))
    }

    @Test func chosenRerankersApplyToEveryMode() async throws {
        let custom = try #require(
            try await BuiltInRerankerCompiler.stage(for: .custom(MarkerReranker(marker: "zebra"), .default))
        )
        #expect(custom.applies(to: .vectorOnly))
        #expect(custom.applies(to: .textOnly))
    }

    @Test func automaticRerankingReordersHybridRecall() async throws {
        let reranker = MarkerReranker(marker: "zebra")
        let stage = try #require(try await automaticStage(reranker))
        let reranked = try await withOrchestrator(reranking: stage) {
            try await $0.recall(query: "apple", mode: .hybrid(alpha: 0.4))
        }
        let plain = try await withOrchestrator(reranking: nil) {
            try await $0.recall(query: "apple", mode: .hybrid(alpha: 0.4))
        }
        #expect(await reranker.callCount == 1)
        #expect(reranked.items.contains { item in item.explanations.contains { $0.hasPrefix("rerank: ") } })
        // Reciprocal-rank fusion (the default options) moves the zebra document up, not to first.
        let rerankedPosition = try #require(docIDs(reranked).firstIndex(of: "d3"))
        let plainPosition = try #require(docIDs(plain).firstIndex(of: "d3"))
        #expect(plainPosition > 0)
        #expect(rerankedPosition < plainPosition)
    }

    @Test func vectorOnlyRecallSkipsTheAutomaticReranker() async throws {
        let reranker = MarkerReranker(marker: "zebra")
        let stage = try #require(try await automaticStage(reranker))
        let reranked = try await withOrchestrator(reranking: stage) {
            try await $0.recall(query: "apple", mode: .vectorOnly)
        }
        let plain = try await withOrchestrator(reranking: nil) {
            try await $0.recall(query: "apple", mode: .vectorOnly)
        }
        #expect(await reranker.callCount == 0)
        #expect(docIDs(reranked) == docIDs(plain))
    }

    @Test func automaticRerankingKeepsTheRetrievalOrderWhenTheRerankerFails() async throws {
        let stage = try #require(try await automaticStage(FailingReranker()))
        let reranked = try await withOrchestrator(reranking: stage) {
            try await $0.recall(query: "apple", mode: .textOnly)
        }
        let plain = try await withOrchestrator(reranking: nil) {
            try await $0.recall(query: "apple", mode: .textOnly)
        }
        #expect(!docIDs(plain).isEmpty)
        #expect(docIDs(reranked) == docIDs(plain))
    }
}
