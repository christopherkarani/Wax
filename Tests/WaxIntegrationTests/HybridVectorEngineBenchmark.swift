#if canImport(XCTest)
import XCTest
import Foundation
@testable import WaxVectorSearch

final class HybridVectorEngineBenchmark: XCTestCase {
    private var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["WAX_RUN_XCTEST_BENCHMARKS"] == "1" || env["WAX_BENCHMARK_METAL"] == "1"
    }

    private func envInt(_ key: String, default defaultValue: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env[key], let value = Int(raw), value > 0 else {
            return defaultValue
        }
        return value
    }

    func testCPUSmallNAccelerateSearch() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_RUN_XCTEST_BENCHMARKS=1 to run benchmarks.") }

        let dimensions = 128
        let vectorCount = 1_000
        let iterations = 10
        let topK = 24
        let vectors = makeVectors(count: vectorCount, dimensions: dimensions)
        let ids = (0..<vectorCount).map(UInt64.init)
        let query = makeQuery(dimensions: dimensions)

        let accelerate = try AccelerateVectorEngine(metric: .cosine, dimensions: dimensions)
        try await accelerate.addBatch(frameIds: ids, vectors: vectors)
        _ = try await accelerate.search(vector: query, topK: topK)

        let accelerateAverage = try await measure(iterations: iterations) {
            _ = try await accelerate.search(vector: query, topK: topK)
        }

        print("\n🧪 Hybrid CPU Benchmark")
        print("   Vectors: \(vectorCount), Dimensions: \(dimensions), TopK: \(topK)")
        print("   Iterations: \(iterations)\n")
        print("   Accelerate avg:  \(String(format: "%.5f", accelerateAverage)) s")
    }

    #if canImport(Metal) && canImport(MetalANNS)
    func testGPULargeNComparison() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_RUN_XCTEST_BENCHMARKS=1 to run benchmarks.") }
        guard MetalANNSVectorEngine.isAvailable else {
            throw XCTSkip("Metal device not available on this runner.")
        }

        let dimensions = 384
        let vectorCount = envInt("WAX_BENCHMARK_GPU_VECTOR_COUNT", default: 10_000)
        let iterations = envInt("WAX_BENCHMARK_GPU_ITERATIONS", default: 10)
        let topK = 24
        let vectors = makeVectors(count: vectorCount, dimensions: dimensions)
        let ids = (0..<vectorCount).map(UInt64.init)
        let query = makeQuery(dimensions: dimensions)

        let legacy = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
        try await legacy.addBatch(frameIds: ids, vectors: vectors)
        _ = try await legacy.search(vector: query, topK: topK)

        let metalANNS = try MetalANNSVectorEngine(metric: .cosine, dimensions: dimensions)
        try await metalANNS.addBatch(frameIds: ids, vectors: vectors)
        _ = try await metalANNS.search(vector: query, topK: topK)

        let legacyAverage = try await measure(iterations: iterations) {
            _ = try await legacy.search(vector: query, topK: topK)
        }
        let metalANNSAverage = try await measure(iterations: iterations) {
            _ = try await metalANNS.search(vector: query, topK: topK)
        }
        let speedup = legacyAverage / metalANNSAverage

        print("\n🧪 Hybrid GPU Benchmark")
        print("   Vectors: \(vectorCount), Dimensions: \(dimensions), TopK: \(topK)")
        print("   Iterations: \(iterations)\n")
        print("   Legacy Metal avg:  \(String(format: "%.5f", legacyAverage)) s")
        print("   MetalANNS avg:     \(String(format: "%.5f", metalANNSAverage)) s")
        print("   Speedup:           \(String(format: "%.2fx", speedup)) faster\n")
    }
    #endif

    private func measure(iterations: Int, block: () async throws -> Void) async throws -> Double {
        var total: Double = 0
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try await block()
            total += CFAbsoluteTimeGetCurrent() - start
        }
        return total / Double(iterations)
    }

    private func makeVectors(count: Int, dimensions: Int) -> [[Float]] {
        (0..<count).map { index in
            (0..<dimensions).map { dim in
                Float((index + dim) % 256) / 255.0
            }
        }
    }

    private func makeQuery(dimensions: Int) -> [Float] {
        (0..<dimensions).map { dim in
            Float((dim * 17) % 97) / 96.0
        }
    }
}
#endif
