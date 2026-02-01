#if canImport(WaxVectorSearchMiniLM)
import Foundation
import XCTest
import WaxVectorSearchMiniLM
@testable import Wax

final class RAGMiniLMBenchmarks: XCTestCase {
    private let scale = BenchmarkScale.current()
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_MINILM"] == "1"
    }

    func testMiniLMEmbeddingPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let text = factory.makeDocument(index: 0)
        let embedder = MiniLMEmbedder()

        _ = try await embedder.embed(text)

        let iterations = max(1, min(5, scale.iterations))
        _ = try await timedSamples(label: "minilm_embed", iterations: iterations, warmup: 0) {
            _ = try await embedder.embed(text)
        }
    }

    func testMiniLMEmbeddingColdStartPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let text = factory.makeDocument(index: 0)

        let iterations = max(1, min(3, scale.iterations))
        _ = try await timedSamples(label: "minilm_cold_start", iterations: iterations, warmup: 0) {
            let embedder = MiniLMEmbedder()
            _ = try await embedder.embed(text)
        }
    }

    func testMiniLMIngestPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let timeout = max(scale.timeout, 240)

        try await TempFiles.withTempFile { url in
            var config = OrchestratorConfig.default
            config.rag.searchTopK = scale.searchTopK
            config.rag.searchMode = .hybrid(alpha: 0.7)
            config.chunking = .tokenCount(targetTokens: 220, overlapTokens: 24)

            let orchestrator = try await MemoryOrchestrator.openMiniLM(at: url, config: config)

            let ingestIterations = max(1, min(3, scale.iterations))
            measureAsync(timeout: timeout, iterations: ingestIterations) {
                for index in 0..<scale.documentCount {
                    let content = factory.makeDocument(index: index)
                    try await orchestrator.remember(content)
                }
                try await orchestrator.flush()
            }

            try await orchestrator.close()
        }
    }

    func testMiniLMRecallPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let timeout = max(scale.timeout, 120)

        try await TempFiles.withTempFile { url in
            var config = OrchestratorConfig.default
            config.rag.searchTopK = scale.searchTopK
            config.rag.searchMode = .hybrid(alpha: 0.7)
            config.chunking = .tokenCount(targetTokens: 220, overlapTokens: 24)

            let orchestrator = try await MemoryOrchestrator.openMiniLM(at: url, config: config)
            for index in 0..<scale.documentCount {
                let content = factory.makeDocument(index: index)
                try await orchestrator.remember(content)
            }
            try await orchestrator.flush()

            let query = factory.queryText
            _ = try await orchestrator.recall(query: query)

            let recallIterations = max(1, min(3, scale.iterations))
            measureAsync(timeout: timeout, iterations: recallIterations) {
                _ = try await orchestrator.recall(query: query)
            }

            try await orchestrator.close()
        }
    }
}
#endif
