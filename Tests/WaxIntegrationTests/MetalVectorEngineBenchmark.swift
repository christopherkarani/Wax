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
}
