#if canImport(XCTest)
import XCTest
import Foundation
@testable import Wax
@testable import WaxCore
@testable import WaxVectorSearch

/// A/B comparison benchmarks to measure the impact of specific optimizations.
/// Compares old (sequential) vs new (batched) approaches directly.
final class OptimizationComparisonBenchmark: XCTestCase {
    
    // Test configuration - use larger dataset to see batch benefits
    private let documentCount = 500
    private let lookupCount = 50  // Typical search topK
    private let iterations = 10
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_OPTIMIZATION"] == "1"
    }
    
    /// Compares batched frameMeta lookup vs sequential lookups
    func testBatchVsSequentialMetadataLookup() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_OPTIMIZATION=1 to run optimization benchmarks.") }
        // Setup: Create a Wax instance with documents
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-benchmark-\(UUID().uuidString).mv2s")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let wax = try await Wax.create(at: tempURL)
        
        // Populate with documents
        for i in 0..<documentCount {
            let content = "Document \(i) content for testing metadata lookup performance"
            _ = try await wax.put(Data(content.utf8), options: FrameMetaSubset(searchText: content))
        }
        try await wax.commit()
        
        // Get all frame IDs for testing
        let allMetas = await wax.frameMetas()
        let frameIds = allMetas.map { $0.id }
        
        // Only look up a subset (like typical search topK results)
        let searchResultIds = Array(frameIds.prefix(lookupCount))
        
        print("\n🧪 Metadata Lookup Comparison Benchmark")
        print("   Total Documents: \(documentCount)")
        print("   Lookup Count (simulating topK results): \(lookupCount)")
        print("   Iterations: \(iterations)\n")
        
        // Benchmark BATCH approach (new - single fetch + dictionary lookup)
        var batchTimes: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            
            // Single fetch for just the ids we need (mirrors UnifiedSearch's batched metadata path)
            let metaById = await wax.frameMetas(frameIds: searchResultIds)
            
            // O(1) lookups for search results
            var lookupResults: [FrameMeta] = []
            for frameId in searchResultIds {
                if let meta = metaById[frameId] {
                    lookupResults.append(meta)
                }
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            batchTimes.append(end - start)
            
            XCTAssertEqual(lookupResults.count, lookupCount)
        }
        
        // Benchmark SEQUENTIAL approach (old - individual actor calls per search result)
        var sequentialTimes: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            
            // Individual actor calls for each search result (old approach)
            var lookupResults: [FrameMeta] = []
            for frameId in searchResultIds {
                if let meta = try? await wax.frameMeta(frameId: frameId) {
                    lookupResults.append(meta)
                }
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            sequentialTimes.append(end - start)
            
            XCTAssertEqual(lookupResults.count, lookupCount)
        }
        
        // Calculate statistics
        let batchAvg = batchTimes.reduce(0, +) / Double(iterations) * 1000
        let sequentialAvg = sequentialTimes.reduce(0, +) / Double(iterations) * 1000
        let speedup = sequentialAvg / batchAvg
        let improvement = ((sequentialAvg - batchAvg) / sequentialAvg) * 100
        
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   BATCH (new):      \(String(format: "%.3f", batchAvg)) ms avg")
        print("   SEQUENTIAL (old): \(String(format: "%.3f", sequentialAvg)) ms avg")
        print("   Speedup:          \(String(format: "%.1f", speedup))x faster")
        print("   Improvement:      \(String(format: "%.1f", improvement))%")
        print("   ─────────────────────────────────────\n")
        
        try await wax.close()
        
        // Note: Batch may not always be faster for small datasets where dict-building overhead dominates
        // The real benefit is in larger datasets with many lookups
        print("   Note: Batch benefits increase with larger datasets and more lookups\n")
    }
    
    /// Compares direct actor calls vs extra Task hop overhead
    func testActorVsTaskHopTokenCounter() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_OPTIMIZATION=1 to run optimization benchmarks.") }
        let counter = try await TokenCounter.shared()
        let testTexts = (0..<100).map { "This is test document number \($0) with some sample content for tokenization." }
        
        print("\n🧪 TokenCounter Actor vs Task Hop Benchmark")
        print("   Texts: \(testTexts.count)")
        print("   Iterations: \(iterations)\n")
        
        // Benchmark DIRECT actor calls
        var directTimes: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            
            var totalTokens = 0
            for text in testTexts {
                totalTokens += await counter.count(text)
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            directTimes.append(end - start)
        }
        
        // Benchmark extra Task hop per call (simulated overhead)
        var taskHopTimes: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            
            var totalTokens = 0
            for text in testTexts {
                totalTokens += await Task { await counter.count(text) }.value
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            taskHopTimes.append(end - start)
        }
        
        // Calculate statistics
        let directAvg = directTimes.reduce(0, +) / Double(iterations) * 1000
        let taskHopAvg = taskHopTimes.reduce(0, +) / Double(iterations) * 1000
        let speedup = taskHopAvg / directAvg
        let improvement = ((taskHopAvg - directAvg) / taskHopAvg) * 100
        
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   DIRECT ACTOR:           \(String(format: "%.3f", directAvg)) ms avg")
        print("   TASK HOP PER CALL:      \(String(format: "%.3f", taskHopAvg)) ms avg")
        print("   Speedup:                \(String(format: "%.1f", speedup))x faster")
        print("   Improvement:            \(String(format: "%.1f", improvement))%")
        print("   ─────────────────────────────────────\n")
        
        XCTAssertGreaterThan(speedup, 1.0, "Direct actor calls should be faster than per-call Task hops")
    }
}
#endif
