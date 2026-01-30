import Testing
@testable import WaxVectorSearch

private func ingestBenchEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_BENCHMARK_METAL_INGEST"] == "1"
}

@Test func metalSwapRemoveSerializationIntegrity() async throws {
    guard MetalVectorEngine.isAvailable else { return }

    let dimensions = 4
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)

    let baseVectors: [(UInt64, [Float])] = [
        (1, [1, 0, 0, 0]),
        (2, [0, 1, 0, 0]),
        (3, [0, 0, 1, 0])
    ]
    for (frameId, vector) in baseVectors {
        try await engine.add(frameId: frameId, vector: vector)
    }

    try await engine.remove(frameId: 2)
    try await engine.add(frameId: 5, vector: [0, 0, 0, 1])

    let data = try await engine.serialize()
    let decoded = try VectorSerializer.decodeVecSegment(from: data)
    guard case .metal(let info, let vectors, let frameIds) = decoded else {
        #expect(Bool(false))
        return
    }

    #expect(info.vectorCount == 3)
    #expect(Set(frameIds) == Set([1, 3, 5]))

    var vectorById: [UInt64: [Float]] = [:]
    for (index, frameId) in frameIds.enumerated() {
        let start = index * dimensions
        let end = start + dimensions
        vectorById[frameId] = Array(vectors[start..<end])
    }

    #expect(vectorById[1] == [1, 0, 0, 0])
    #expect(vectorById[3] == [0, 0, 1, 0])
    #expect(vectorById[5] == [0, 0, 0, 1])
}

@Test func metalIngestScalingBenchmark() async throws {
    guard ingestBenchEnabled() else { return }
    guard MetalVectorEngine.isAvailable else { return }

    let dimensions = 128
    let sizes = [10_000, 50_000, 100_000]
    let batchSize = 256

    let clock = ContinuousClock()
    for count in sizes {
        let engine = try MetalVectorEngine(metric: .cosine, dimensions: dimensions)
        let frameIds = (0..<count).map { UInt64($0) }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(count)
        for i in 0..<count {
            var vector = [Float](repeating: 0, count: dimensions)
            vector[i % dimensions] = 1
            vectors.append(vector)
        }

        let start = clock.now
        for startIndex in stride(from: 0, to: count, by: batchSize) {
            let end = min(startIndex + batchSize, count)
            let ids = Array(frameIds[startIndex..<end])
            let batchVectors = Array(vectors[startIndex..<end])
            try await engine.addBatch(frameIds: ids, vectors: batchVectors)
        }
        let duration = clock.now - start
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        print("🧪 metal_addBatch_\(count): \(String(format: "%.4f", seconds)) s")
    }
}
