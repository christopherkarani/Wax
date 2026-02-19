#if canImport(WaxVectorSearchMiniLM) && canImport(XCTest)
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
        let embedder = try MiniLMEmbedder()

        _ = try await embedder.embed(text)

        let iterations = max(1, min(5, scale.iterations))
        _ = try await timedSamples(label: "minilm_embed", iterations: iterations, warmup: 0) {
            _ = try await embedder.embed(text)
        }
    }

    func testMiniLMBatchEmbeddingThroughput() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let embedder = try MiniLMEmbedder()

        try? await embedder.prewarm()

        // NOTE: This benchmark intentionally uses a small batch size to match the current ingest default
        // (and avoid relying on model-export-specific max batch support).
        let batchSize = 32
        let texts = (0..<batchSize).map { factory.makeDocument(index: $0) }
        _ = try await embedder.embed(batch: texts)

        let iterations = max(1, min(5, scale.iterations))
        _ = try await timedSamples(label: "minilm_embed_batch32", iterations: iterations, warmup: 0) {
            _ = try await embedder.embed(batch: texts)
        }
    }

    func testMiniLMEmbeddingColdStartPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let text = factory.makeDocument(index: 0)

        let iterations = max(1, min(3, scale.iterations))
        _ = try await timedSamples(label: "minilm_cold_start", iterations: iterations, warmup: 0) {
            let embedder = try MiniLMEmbedder()
            _ = try await embedder.embed(text)
        }
    }

    func testMiniLMOpenAndFirstRecallOnExistingStoreSamples() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run MiniLM benchmarks.") }
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)

        try await TempFiles.withTempFile { url in
            var config = OrchestratorConfig.default
            config.rag.searchTopK = scale.searchTopK
            config.rag.searchMode = .hybrid(alpha: 0.7)
            config.chunking = .tokenCount(targetTokens: 220, overlapTokens: 24)
            let localConfig = config

            do {
                let orchestrator = try await MemoryOrchestrator.openMiniLM(at: url, config: localConfig)
                for index in 0..<scale.documentCount {
                    let content = factory.makeDocument(index: index)
                    try await orchestrator.remember(content)
                }
                try await orchestrator.flush()
                try await orchestrator.close()
            }

            let iterations = max(1, min(3, scale.iterations))
            let query = factory.queryText
            _ = try await timedSamples(label: "minilm_open_plus_first_recall", iterations: iterations, warmup: 0) {
                let orchestrator = try await MemoryOrchestrator.openMiniLM(at: url, config: localConfig)
                _ = try await orchestrator.recall(query: query)
                try await orchestrator.close()
            }
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
