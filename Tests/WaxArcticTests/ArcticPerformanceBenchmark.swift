#if canImport(CoreML) && canImport(XCTest)
import Foundation
import XCTest
@preconcurrency import CoreML
import WaxBertTokenizer
import WaxVectorSearchMiniLM
import WaxVectorSearchArctic
import WaxVectorSearch
@testable import Wax

/// A/B performance comparison: MiniLM vs Arctic, and tokenizer regression check.
/// Run with WAX_BENCHMARK_ARCTIC=1 to enable.
final class ArcticPerformanceBenchmark: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_ARCTIC"] == "1"
    }

    private let mediumText = "The quick brown fox jumps over the lazy dog. Swift is a programming language for iOS and macOS development."
    private let batchTexts: [String] = (0..<16).map {
        "Document \($0): Swift performance and vector search embeddings for on-device RAG."
    }

    // MARK: - Tokenizer Regression

    func testTokenizerThroughputAfterExtraction() throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_ARCTIC=1") }

        let tokenizer = try BertTokenizer()
        let iterations = 1_000

        // Warm up
        _ = try tokenizer.buildModelTokens(sentence: mediumText)

        var elapsed: Double = 0
        measure {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                _ = try! tokenizer.buildModelTokens(sentence: mediumText)
            }
            elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        print("Tokenizer: \(iterations) calls in \(String(format: "%.1f", elapsed))ms (\(String(format: "%.3f", elapsed / Double(iterations)))ms/call)")
    }

    // MARK: - Single Embed Comparison

    func testMiniLMSingleEmbedLatency() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_ARCTIC=1") }
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("MiniLM requires macOS 15.0 or iOS 18.0") }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let embedder = try MiniLMEmbedder(config: .init(batchSize: 1, modelConfiguration: config))
        try await embedder.prewarm(batchSize: 1)

        var times: [Double] = []
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await embedder.embed(mediumText)
            let end = CFAbsoluteTimeGetCurrent()
            times.append((end - start) * 1000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min()!
        let p50 = times.sorted()[times.count / 2]
        print("MiniLM single embed: avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms p50=\(String(format: "%.1f", p50))ms")
    }

    func testArcticSingleEmbedLatency() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_ARCTIC=1") }
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("Arctic requires macOS 15.0 or iOS 18.0") }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let embedder = try ArcticEmbedder(config: .init(batchSize: 1, modelConfiguration: config))
        try await embedder.prewarm(batchSize: 1)

        var times: [Double] = []
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await embedder.embed(mediumText)
            let end = CFAbsoluteTimeGetCurrent()
            times.append((end - start) * 1000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min()!
        let p50 = times.sorted()[times.count / 2]
        print("Arctic single embed: avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms p50=\(String(format: "%.1f", p50))ms")
    }

    func testArcticQueryEmbedLatency() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_ARCTIC=1") }
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("Arctic requires macOS 15.0 or iOS 18.0") }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let embedder = try ArcticEmbedder(config: .init(batchSize: 1, modelConfiguration: config))
        try await embedder.prewarm(batchSize: 1)

        var times: [Double] = []
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await embedder.embedQuery(mediumText)
            let end = CFAbsoluteTimeGetCurrent()
            times.append((end - start) * 1000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min()!
        let p50 = times.sorted()[times.count / 2]
        print("Arctic query embed: avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", min))ms p50=\(String(format: "%.1f", p50))ms")
    }

    // MARK: - Batch Comparison

    func testMiniLMBatchThroughput() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_ARCTIC=1") }
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("MiniLM requires macOS 15.0 or iOS 18.0") }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let embedder = try MiniLMEmbedder(config: .init(batchSize: 256, modelConfiguration: config))
        try await embedder.prewarm(batchSize: 4)

        var times: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await embedder.embed(batch: batchTexts)
            let end = CFAbsoluteTimeGetCurrent()
            times.append((end - start) * 1000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        let perText = avg / Double(batchTexts.count)
        print("MiniLM batch(\(batchTexts.count)): avg=\(String(format: "%.1f", avg))ms per_text=\(String(format: "%.1f", perText))ms")
    }

    func testArcticBatchThroughput() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_ARCTIC=1") }
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("Arctic requires macOS 15.0 or iOS 18.0") }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let embedder = try ArcticEmbedder(config: .init(batchSize: 256, modelConfiguration: config))
        try await embedder.prewarm(batchSize: 4)

        var times: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await embedder.embed(batch: batchTexts)
            let end = CFAbsoluteTimeGetCurrent()
            times.append((end - start) * 1000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        let perText = avg / Double(batchTexts.count)
        print("Arctic batch(\(batchTexts.count)): avg=\(String(format: "%.1f", avg))ms per_text=\(String(format: "%.1f", perText))ms")
    }
}
#endif
