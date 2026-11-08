import Foundation
import WaxCore
import WaxVectorSearch

/// A reranker and its options, applied to the ranked candidates before context assembly.
package struct RerankStage: Sendable {
    package let provider: any RerankingProvider
    package let options: RerankingOptions

    package init(provider: any RerankingProvider, options: RerankingOptions) {
        self.provider = provider
        self.options = options
    }

    /// Rescores the first ``RerankingOptions/candidateCount`` results and reorders them by
    /// ``RerankingOptions/fusion``; results below that window keep their order. `text`
    /// supplies each candidate's text. Scores stay the retrieval scores: the order changes,
    /// and each reranked result gains an explanation with its reranker score.
    package func rerank(
        query: String,
        results: [SearchResponse.Result],
        text: (SearchResponse.Result) async -> String
    ) async throws -> [SearchResponse.Result] {
        let window = Array(results.prefix(options.candidateCount))
        guard !window.isEmpty else { return results }
        var documents: [String] = []
        documents.reserveCapacity(window.count)
        for result in window {
            documents.append(await text(result))
        }
        let scores = try await provider.scores(query: query, documents: documents)
        guard scores.count == window.count else {
            throw WaxError.io("Reranker returned \(scores.count) scores for \(window.count) documents.")
        }
        guard scores.allSatisfy(\.isFinite) else {
            throw WaxError.io("Reranker returned a non-finite score.")
        }
        let reordered = Self.fusedOrder(scores: scores, fusion: options.fusion).map { index in
            var result = window[index]
            result.explanations.append("rerank: score \(scores[index]), retrieval rank \(index + 1)")
            return result
        }
        return reordered + results.dropFirst(window.count)
    }

    /// The new order of candidates `0..<scores.count`, given in retrieval order with their
    /// reranker scores. Ties keep the retrieval order.
    package static func fusedOrder(scores: [Float], fusion: RerankingFusion) -> [Int] {
        let retrieval = Array(scores.indices)
        let rerankerOrder = retrieval.sorted { lhs, rhs in
            scores[lhs] != scores[rhs] ? scores[lhs] > scores[rhs] : lhs < rhs
        }
        switch fusion {
        case .rerankerOrder:
            return rerankerOrder
        case .reciprocalRank(let k):
            var rerankerRank = Array(repeating: 0, count: scores.count)
            for (position, index) in rerankerOrder.enumerated() {
                rerankerRank[index] = position + 1
            }
            let fused = retrieval.map { index in
                1 / Double(k + index + 1) + 1 / Double(k + rerankerRank[index])
            }
            return retrieval.sorted { lhs, rhs in
                fused[lhs] != fused[rhs] ? fused[lhs] > fused[rhs] : lhs < rhs
            }
        }
    }
}
