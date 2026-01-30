import Testing
@testable import WaxVectorSearch

private func quantBenchEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_BENCHMARK_USEARCH_QUANT"] == "1"
}

private func timedMean(
    label: String,
    iterations: Int,
    _ block: @escaping @Sendable () async throws -> Void
) async throws {
    let clock = ContinuousClock()
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = clock.now
        try await block()
        let duration = clock.now - start
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        samples.append(seconds)
    }
    let mean = samples.reduce(0, +) / Double(max(1, samples.count))
    print("🧪 \(label): mean \(String(format: "%.5f", mean)) s")
}

@Test func usearchQuantizationBenchmark() async throws {
    guard quantBenchEnabled() else { return }

    let dimensions = 128
    let vectorCount = 20_000
    let topK = 24
    let iterations = 10

    let vectors: [[Float]] = (0..<vectorCount).map { idx in
        var vector = [Float](repeating: 0, count: dimensions)
        vector[idx % dimensions] = 1
        return vector
    }
    let query = vectors[0]

    for quantization in [VecQuantization.f32, .f16, .i8] {
        do {
            let engine = try USearchVectorEngine(metric: .cosine, dimensions: dimensions, quantization: quantization)
            let frameIds = (0..<vectorCount).map { UInt64($0) }
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
            _ = try await engine.search(vector: query, topK: topK)

            try await timedMean(label: "usearch_\(quantization)_search", iterations: iterations) {
                _ = try await engine.search(vector: query, topK: topK)
            }
        } catch {
            print("🧪 usearch_\(quantization)_search: skipped (\(error))")
        }
    }
}
