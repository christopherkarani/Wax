import XCTest
import Foundation
@testable import Wax
@testable import WaxVectorSearch
import Metal

final class MetalVectorEngineBenchmark: XCTestCase {
    
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_METAL"] == "1"
    }
    
    func testMetalSearchPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_METAL=1 to run Metal benchmarks.") }
        
        let dimensions = 128
        let vectorCount = 1000
        let iterations = 5
        let topK = 24
        
        print("\n🧪 Metal Vector Search Benchmark")
        print("   Vectors: \(vectorCount), Dimensions: \(dimensions), TopK: \(topK)")
        print("   Iterations: \(iterations)\n")
        
        // Build engine and populate with deterministic vectors so performance is repeatable.
        let engine = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
        for index in 0..<vectorCount {
            var vector = [Float](repeating: 0, count: dimensions)
            for dim in 0..<dimensions {
                vector[dim] = Float((index + dim) % 256) / 255.0
            }
            try await engine.add(frameId: UInt64(index), vector: vector)
        }

        let queryVector: [Float] = (0..<dimensions).map { _ in Float.random(in: 0...1) }

        var times: [Double] = []
        for iteration in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await engine.search(vector: queryVector, topK: topK)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            times.append(elapsed)
            print("   Iteration \(iteration + 1): \(String(format: "%.5f", elapsed)) s")
        }

        let avg = times.reduce(0, +) / Double(times.count)
        let perVector = (avg * 1_000.0) / Double(vectorCount)

        print("\n   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   Metal search avg: \(String(format: "%.5f", avg)) s")
        print("   Latency per vector: \(String(format: "%.4f", perVector)) ms")
        print("   ─────────────────────────────────────\n")
    }
    
    /// Tests the lazy GPU sync optimization by comparing cold vs warm search performance.
    /// Cold search = first search after vectors added (requires GPU sync)
    /// Warm search = subsequent searches (no GPU sync needed)
    func testMetalLazyGPUSyncPerformance() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_METAL=1 to run Metal benchmarks.") }
        
        let dimensions = 384  // MiniLM dimensions
        let vectorCount = 10_000
        let warmIterations = 10
        let topK = 24
        
        print("\n🧪 Metal Lazy GPU Sync Benchmark (Optimization Test)")
        print("   Vectors: \(vectorCount), Dimensions: \(dimensions), TopK: \(topK)")
        print("   Warm iterations: \(warmIterations)\n")
        
        // Build engine and populate with vectors
        let engine = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
        for index in 0..<vectorCount {
            var vector = [Float](repeating: 0, count: dimensions)
            for dim in 0..<dimensions {
                vector[dim] = Float((index + dim) % 256) / 255.0
            }
            try await engine.add(frameId: UInt64(index), vector: vector)
        }

        let queryVector: [Float] = (0..<dimensions).map { _ in Float.random(in: 0...1) }

        // Cold search - first search requires GPU sync
        let coldStart = CFAbsoluteTimeGetCurrent()
        _ = try await engine.search(vector: queryVector, topK: topK)
        let coldTime = CFAbsoluteTimeGetCurrent() - coldStart
        
        // Warm searches - subsequent searches skip GPU sync
        var warmTimes: [Double] = []
        for _ in 0..<warmIterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await engine.search(vector: queryVector, topK: topK)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            warmTimes.append(elapsed)
        }
        
        let warmAvg = warmTimes.reduce(0, +) / Double(warmTimes.count)
        let warmMin = warmTimes.min() ?? 0
        let warmMax = warmTimes.max() ?? 0
        let speedup = coldTime / warmAvg
        
        // Calculate memory bandwidth saved per warm query
        let bytesSaved = vectorCount * dimensions * MemoryLayout<Float>.stride
        let mbSaved = Double(bytesSaved) / (1024 * 1024)
        
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   COLD search (with GPU sync): \(String(format: "%.5f", coldTime)) s")
        print("   WARM search avg (no sync):   \(String(format: "%.5f", warmAvg)) s")
        print("   WARM search min:             \(String(format: "%.5f", warmMin)) s")
        print("   WARM search max:             \(String(format: "%.5f", warmMax)) s")
        print("")
        print("   ✅ Warm search speedup:      \(String(format: "%.1f", speedup))x faster")
        print("   ✅ Memory bandwidth saved:   \(String(format: "%.1f", mbSaved)) MB per warm query")
        print("   ─────────────────────────────────────\n")
        
        // Assert that warm searches are faster than cold (speedup varies by scale)
        // At 10K vectors with 384 dims, expect ~1.3x speedup
        // At smaller scales, speedup can be 3-5x as GPU compute dominates copy time
        XCTAssertGreaterThan(speedup, 1.1, "Warm searches should be faster than cold search")
    }
    
    /// Tests multiple search-after-add cycles to validate lazy sync correctness.
    func testMetalSearchAfterAddCorrectness() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_BENCHMARK_METAL=1 to run Metal benchmarks.") }
        
        let dimensions = 128
        let topK = 5
        
        print("\n🧪 Metal Search-After-Add Correctness Test\n")
        
        let engine = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
        
        // Add initial vectors
        for i in 0..<100 {
            var vector = [Float](repeating: Float(i) / 100.0, count: dimensions)
            vector[0] = 1.0  // Make first component distinctive
            try await engine.add(frameId: UInt64(i), vector: vector)
        }
        
        // First search
        let query1: [Float] = [Float](repeating: 0.5, count: dimensions)
        let results1 = try await engine.search(vector: query1, topK: topK)
        XCTAssertEqual(results1.count, topK, "Should return topK results")
        
        // Add more vectors
        for i in 100..<200 {
            var vector = [Float](repeating: Float(i) / 200.0, count: dimensions)
            vector[0] = 0.5  // Closer to query
            try await engine.add(frameId: UInt64(i), vector: vector)
        }
        
        // Second search - should see new vectors
        let results2 = try await engine.search(vector: query1, topK: topK)
        XCTAssertEqual(results2.count, topK, "Should return topK results after adding more vectors")
        
        // Verify new vectors appear in results (they should be closer to query)
        let newVectorIds = Set(100..<200).map { UInt64($0) }
        let foundNewVectors = results2.filter { newVectorIds.contains($0.frameId) }.count
        XCTAssertGreaterThan(foundNewVectors, 0, "New vectors should appear in results since they're closer to query")
        
        print("   ✅ Search correctly reflects newly added vectors")
        print("   ✅ Lazy GPU sync maintains correctness\n")
    }
}
