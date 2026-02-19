#if canImport(WaxVectorSearchMiniLM) && canImport(XCTest)
import Foundation
import XCTest
import WaxVectorSearchMiniLM
@testable import Wax
@testable import WaxVectorSearch

/// Benchmark comparing batch vs sequential embedding performance.
/// This directly measures the impact of the BatchEmbeddingProvider optimization.
final class BatchEmbeddingBenchmark: XCTestCase {
    
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_MINILM"] == "1"
    }
    
    /// Test batch embedding vs sequential embedding performance
    func testBatchVsSequentialEmbedding() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run batch embedding benchmark.") }
        
        let embedder = try MiniLMEmbedder()
        let textCount = 32
        let iterations = 3
        
        // Generate test texts
        let texts = (0..<textCount).map { index in
            "Document \(index) about Swift performance. Vector search uses embeddings for semantic similarity. Batch processing improves throughput significantly by amortizing model loading overhead."
        }
        
        print("\n🧪 Batch vs Sequential Embedding Benchmark")
        print("   Texts: \(textCount), Iterations: \(iterations)")
        print("")
        
        // Warm up
        _ = try await embedder.embed(texts[0])
        _ = try await embedder.embed(batch: texts)
        
        // Benchmark SEQUENTIAL embedding (old approach)
        var sequentialTimes: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            
            for text in texts {
                _ = try await embedder.embed(text)
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            sequentialTimes.append(end - start)
        }
        
        // Benchmark BATCH embedding (new approach)
        var batchTimes: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            
            _ = try await embedder.embed(batch: texts)
            
            let end = CFAbsoluteTimeGetCurrent()
            batchTimes.append(end - start)
        }
        
        // Calculate statistics
        let sequentialAvg = sequentialTimes.reduce(0, +) / Double(iterations) * 1000
        let batchAvg = batchTimes.reduce(0, +) / Double(iterations) * 1000
        let speedup = sequentialAvg / batchAvg
        let improvement = ((sequentialAvg - batchAvg) / sequentialAvg) * 100
        let perTextSeq = sequentialAvg / Double(textCount)
        let perTextBatch = batchAvg / Double(textCount)
        
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   SEQUENTIAL (old):    \(String(format: "%.1f", sequentialAvg)) ms total (\(String(format: "%.2f", perTextSeq)) ms/text)")
        print("   BATCH (new):         \(String(format: "%.1f", batchAvg)) ms total (\(String(format: "%.2f", perTextBatch)) ms/text)")
        print("   Speedup:             \(String(format: "%.2f", speedup))x faster")
        print("   Improvement:         \(String(format: "%.1f", improvement))%")
        print("   ─────────────────────────────────────\n")
        
        // Assert that batch is at least somewhat faster (allows for variance)
        XCTAssertGreaterThan(speedup, 0.8, "Batch embedding should not be significantly slower than sequential")
    }
    
    /// Test batch embedding with varying batch sizes
    func testBatchEmbeddingScaling() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run batch embedding scaling benchmark.") }
        
        let embedder = try MiniLMEmbedder()
        let batchSizes = [8, 16, 32, 64]
        
        // Generate test texts
        let maxTexts = 64
        let allTexts = (0..<maxTexts).map { index in
            "Document \(index) about Swift performance and vector search optimization techniques."
        }
        
        print("\n🧪 Batch Embedding Scaling Benchmark")
        print("   ─────────────────────────────────────")
        
        // Warm up
        _ = try await embedder.embed(allTexts[0])
        _ = try await embedder.embed(batch: Array(allTexts.prefix(batchSizes.max() ?? 1)))
        
        for batchSize in batchSizes {
            let texts = Array(allTexts.prefix(batchSize))
            
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await embedder.embed(batch: texts)
            let end = CFAbsoluteTimeGetCurrent()
            
            let totalMs = (end - start) * 1000
            let perTextMs = totalMs / Double(batchSize)
            let throughput = Double(batchSize) / (end - start)
            
            print("   Batch size \(String(format: "%2d", batchSize)): \(String(format: "%6.1f", totalMs)) ms total, \(String(format: "%.2f", perTextMs)) ms/text, \(String(format: "%.1f", throughput)) texts/sec")
        }
        
        print("   ─────────────────────────────────────\n")
    }
    
    /// Test full orchestrator ingest with batch embedding vs sequential fallback
    func testOrchestratorBatchEmbeddingPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_MINILM=1 to run orchestrator batch embedding benchmark.") }
        
        let documentCount = 100
        let iterations = 2
        
        print("\n🧪 Orchestrator Ingest with Batch Embedding")
        print("   Documents: \(documentCount), Iterations: \(iterations)")
        print("")
        
        // Generate test documents
        let documents = (0..<documentCount).map { index in
            "Document \(index) about Wax RAG performance. Vector search compares embeddings to find semantic neighbors. Hybrid search fuses lexical and vector signals for recall. Token budgets keep prompts stable across runs."
        }
        
        var times: [Double] = []
        
        for iteration in 0..<iterations {
            try await TempFiles.withTempFile { url in
                var config = OrchestratorConfig.default
                config.rag.searchTopK = 10
                config.rag.searchMode = .hybrid(alpha: 0.7)
                config.chunking = .tokenCount(targetTokens: 500, overlapTokens: 50)
                config.embeddingCacheCapacity = 256  // Enable embedding cache
                
                let orchestrator = try await MemoryOrchestrator.openMiniLM(at: url, config: config)
                
                let start = CFAbsoluteTimeGetCurrent()
                
                for document in documents {
                    try await orchestrator.remember(document)
                }
                try await orchestrator.flush()
                
                let end = CFAbsoluteTimeGetCurrent()
                times.append(end - start)
                
                print("   Iteration \(iteration + 1): \(String(format: "%.2f", end - start)) s")
                
                try await orchestrator.close()
            }
        }
        
        let avgTime = times.reduce(0, +) / Double(iterations)
        let docsPerSec = Double(documentCount) / avgTime
        
        print("")
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   Average time:        \(String(format: "%.2f", avgTime)) s")
        print("   Throughput:          \(String(format: "%.1f", docsPerSec)) docs/sec")
        print("   ─────────────────────────────────────\n")
    }
}
#endif
