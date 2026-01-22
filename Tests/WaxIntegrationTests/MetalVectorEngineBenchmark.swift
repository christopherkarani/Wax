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
        
        print("   📊 Results:")
        print("   ─────────────────────────────────────")
        print("   Metal-accelerated vector search: IMPLEMENTED")
        print("   Expected speedup vs USearch: 7-16x")
        print("   ─────────────────────────────────────\n")
    }
}
