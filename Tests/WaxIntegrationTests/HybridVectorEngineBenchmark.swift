#if canImport(XCTest)
import XCTest
import Foundation
@testable import WaxVectorSearch
#if canImport(Metal) && canImport(MetalANNS)
import MetalANNS
#endif

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

    private func envCounts(_ key: String, default defaultValue: [Int]) -> [Int] {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env[key], !raw.isEmpty else { return defaultValue }
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.filter { $0 > 0 }.isEmpty ? defaultValue : parsed.filter { $0 > 0 }
    }

    func testCPUSmallNAccelerateSearch() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_RUN_XCTEST_BENCHMARKS=1 to run benchmarks.") }

        let dimensions = 128
        let vectorCount = 1_000
        let iterations = 10
        let topK = 24
        let vectors = makeVectors(offset: 0, count: vectorCount, dimensions: dimensions)
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
        let topK = 24
        let defaultIterations = envInt("WAX_BENCHMARK_GPU_ITERATIONS", default: 10)
        let counts = envCounts(
            "WAX_BENCHMARK_GPU_VECTOR_COUNTS",
            default: [envInt("WAX_BENCHMARK_GPU_VECTOR_COUNT", default: 10_000)]
        )
        let query = makeQuery(dimensions: dimensions)
        print("\n🧪 Hybrid GPU scale sweep")
        print("   MetalANNS 0.3.0 · dim \(dimensions) · topK \(topK)")
        print("   Scales: \(counts.map { $0.formatted() }.joined(separator: ", "))\n")
        let header = "scale\tengine\tingest_s\twarm_ms\tqps"
        print("   \(header)")
        let outPath = ProcessInfo.processInfo.environment["WAX_BENCHMARK_OUT"]
        if let outPath {
            let banner = "# MetalANNS 0.3.0 GPU sweep dim=\(dimensions) topK=\(topK)\n\(header)\n"
            try? banner.write(toFile: outPath, atomically: true, encoding: .utf8)
        }

        for vectorCount in counts {
            let iterations = vectorCount >= 100_000 ? min(defaultIterations, 5) : defaultIterations
            try await measureScale(
                label: "legacy-metal",
                vectorCount: vectorCount,
                dimensions: dimensions,
                topK: topK,
                iterations: iterations,
                query: query,
                makeEngine: { try MetalVectorEngine(metric: .cosine, dimensions: dimensions) }
            )
            let annsDegree = graphDegree(for: vectorCount)
            try await measureScale(
                label: "metalanns-exact",
                vectorCount: vectorCount,
                dimensions: dimensions,
                topK: topK,
                iterations: iterations,
                query: query,
                makeEngine: {
                    try MetalANNSVectorEngine(
                        metric: .cosine,
                        dimensions: dimensions,
                        searchMode: .exact,
                        degree: annsDegree
                    )
                }
            )
            try await measureScale(
                label: "metalanns-fast",
                vectorCount: vectorCount,
                dimensions: dimensions,
                topK: topK,
                iterations: iterations,
                query: query,
                makeEngine: {
                    try MetalANNSVectorEngine(
                        metric: .cosine,
                        dimensions: dimensions,
                        searchMode: .fast,
                        degree: annsDegree
                    )
                }
            )
        }
        print("")
    }

    /// Same-process split: raw MetalANNS VectorIndex vs Wax MetalANNSVectorEngine.
    func testGPUWrapperBreakdown() async throws {
        guard isEnabled else { throw XCTSkip("Set WAX_RUN_XCTEST_BENCHMARKS=1 to run benchmarks.") }
        guard MetalANNSVectorEngine.isAvailable else {
            throw XCTSkip("Metal device not available on this runner.")
        }

        let dimensions = 384
        let topK = 24
        let iterations = envInt("WAX_BENCHMARK_GPU_ITERATIONS", default: 8)
        let counts = envCounts("WAX_BENCHMARK_GPU_VECTOR_COUNTS", default: [10_000, 100_000])
        let query = makeQuery(dimensions: dimensions)
        print("\n🧪 Wax wrapper breakdown vs raw VectorIndex")
        print("   dim \(dimensions) · topK \(topK) · iterations \(iterations)")
        print("   n\tpath\twarm_ms\tprepare_ms\tindex_ms\tmap_ms")

        for vectorCount in counts {
            let vectors = makeVectors(offset: 0, count: vectorCount, dimensions: dimensions)
            let ids = (0..<vectorCount).map(UInt64.init)
            var configuration = IndexConfiguration.default
            configuration.metric = .cosine
            configuration.degree = graphDegree(for: vectorCount)
            configuration.searchMode = .exact

            let builder = VectorIndex<UInt64, VectorIndexState.Unbuilt>(configuration: configuration)
            let raw = try await builder.build(vectors: vectors, ids: ids)
            _ = try await raw.search(query: query, topK: topK)
            let rawMs = try await measure(iterations: iterations) {
                _ = try await raw.search(query: query, topK: topK)
            } * 1_000

            let engine = try MetalANNSVectorEngine(
                metric: .cosine,
                dimensions: dimensions,
                searchMode: .exact,
                degree: graphDegree(for: vectorCount)
            )
            try await engine.addBatch(frameIds: ids, vectors: vectors)
            _ = try await engine.search(vector: query, topK: topK)
            var prepare = 0.0
            var index = 0.0
            var map = 0.0
            var total = 0.0
            for _ in 0..<iterations {
                let timed = try await engine.searchTimed(vector: query, topK: topK)
                prepare += timed.timing.prepareMs
                index += timed.timing.indexMs
                map += timed.timing.mapMs
                total += timed.timing.totalMs
            }
            let n = Double(iterations)
            print(
                "   \(vectorCount)\traw-vectorindex\t\(String(format: "%.3f", rawMs))\t-\t-\t-"
            )
            print(
                "   \(vectorCount)\twax-engine\t\(String(format: "%.3f", total / n))\t\(String(format: "%.3f", prepare / n))\t\(String(format: "%.3f", index / n))\t\(String(format: "%.3f", map / n))"
            )
        }
        print("")
    }

    private func measureScale(
        label: String,
        vectorCount: Int,
        dimensions: Int,
        topK: Int,
        iterations: Int,
        query: [Float],
        makeEngine: () throws -> any VectorSearchEngine
    ) async throws {
        do {
            let engine = try makeEngine()
            let ingestStart = CFAbsoluteTimeGetCurrent()
            try await ingest(engine, count: vectorCount, dimensions: dimensions)
            _ = try await engine.search(vector: query, topK: topK)
            let ingestSeconds = CFAbsoluteTimeGetCurrent() - ingestStart

            let average = try await measure(iterations: iterations) {
                _ = try await engine.search(vector: query, topK: topK)
            }
            let warmMs = average * 1_000
            let qps = average > 0 ? 1.0 / average : 0
            let line = "\(vectorCount)\t\(label)\t\(String(format: "%.3f", ingestSeconds))\t\(String(format: "%.3f", warmMs))\t\(String(format: "%.0f", qps))"
            print("   \(line)")
            appendBenchmarkLine(line)
        } catch {
            let line = "\(vectorCount)\t\(label)\tFAIL\t\(error)"
            print("   \(line)")
            appendBenchmarkLine(line)
        }
    }

    private func appendBenchmarkLine(_ line: String) {
        guard let outPath = ProcessInfo.processInfo.environment["WAX_BENCHMARK_OUT"] else { return }
        guard let handle = FileHandle(forWritingAtPath: outPath) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    /// NN-Descent requires degree < n and a power of two ≤ 64. Production default is 32.
    private func graphDegree(for vectorCount: Int) -> Int {
        if vectorCount > 32 { return 32 }
        var degree = 1
        while degree * 2 < vectorCount && degree < 32 {
            degree *= 2
        }
        return max(1, degree)
    }

    private func ingest(
        _ engine: any VectorSearchEngine,
        count: Int,
        dimensions: Int
    ) async throws {
        // One-shot ingest so MetalANNS sizes graph capacity to n. Chunked inserts
        // after a smaller first build throw indexCapacityExceeded (0.3.0).
        let ids = (0..<count).map(UInt64.init)
        let vectors = makeVectors(offset: 0, count: count, dimensions: dimensions)
        try await engine.addBatch(frameIds: ids, vectors: vectors)
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

    private func makeVectors(offset: Int, count: Int, dimensions: Int) -> [[Float]] {
        var rows = [[Float]]()
        rows.reserveCapacity(count)
        var row = [Float](repeating: 0, count: dimensions)
        for index in 0..<count {
            let base = offset + index
            for dim in 0..<dimensions {
                row[dim] = Float((base + dim) % 256) / 255.0
            }
            rows.append(row)
        }
        return rows
    }

    private func makeQuery(dimensions: Int) -> [Float] {
        (0..<dimensions).map { dim in
            Float((dim * 17) % 97) / 96.0
        }
    }
}
#endif
