import Testing
@testable import WaxVectorSearch

private func scalingBenchEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_BENCHMARK_VECTOR_SCALE"] == "1"
}

@Test func vectorSearchScalingBenchmark() async throws {
    guard scalingBenchEnabled() else { return }

    let dimensions = 128
    let sizes = [10_000, 50_000, 100_000]
    let topK = 24

    for count in sizes {
        let clock = ContinuousClock()
        let vectors: [[Float]] = (0..<count).map { idx in
            var vector = [Float](repeating: 0, count: dimensions)
            vector[idx % dimensions] = 1
            return vector
        }
        let frameIds = (0..<count).map { UInt64($0) }
        let query = vectors[0]

        let cpu = try USearchVectorEngine(metric: .cosine, dimensions: dimensions, quantization: .f32)
        try await cpu.addBatch(frameIds: frameIds, vectors: vectors)
        _ = try await cpu.search(vector: query, topK: topK)

        let cpuStart = clock.now
        _ = try await cpu.search(vector: query, topK: topK)
        let cpuDuration = clock.now - cpuStart
        let cpuSeconds = Double(cpuDuration.components.seconds) +
            Double(cpuDuration.components.attoseconds) / 1_000_000_000_000_000_000
        print("🧪 vector_search_usearch_\(count): \(String(format: "%.4f", cpuSeconds)) s")

        if MetalVectorEngine.isAvailable {
            let metal = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
            for (frameId, vector) in zip(frameIds, vectors) {
                try await metal.add(frameId: frameId, vector: vector)
            }
            _ = try await metal.search(vector: query, topK: topK)

            let metalStart = clock.now
            _ = try await metal.search(vector: query, topK: topK)
            let metalDuration = clock.now - metalStart
            let metalSeconds = Double(metalDuration.components.seconds) +
                Double(metalDuration.components.attoseconds) / 1_000_000_000_000_000_000
            print("🧪 vector_search_metal_\(count): \(String(format: "%.4f", metalSeconds)) s")
        }
    }
}
