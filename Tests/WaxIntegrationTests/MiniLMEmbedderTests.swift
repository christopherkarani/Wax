import Foundation
import Testing

#if canImport(WaxVectorSearchMiniLM)
#if canImport(CoreML)
import CoreML
#endif
import WaxBertTokenizer
import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
private struct StubMiniLMModel: MiniLMEmbeddingModel {
    let single: [Float]?
    let batch: [[Float]]?
    var error: Error?

    func encode(sentence: String) async throws -> [Float]? {
        if let error { throw error }
        return single
    }

    #if canImport(CoreML)
    let computeUnits: MLComputeUnits = .cpuOnly

    func encode(batch sentences: [String], reuseBuffers: inout BatchInputBuffers?) async throws -> [[Float]]? {
        if let error { throw error }
        return batch
    }
    #else
    func encode(batch sentences: [String]) async throws -> [[Float]]? {
        if let error { throw error }
        return batch
    }
    #endif
}

private struct StubMiniLMError: Error {}

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbedderNormalizesDirectOutputs() async throws {
    var vector = Array(repeating: Float(0), count: 384)
    vector[0] = 3
    vector[1] = 4
    let embedder = MiniLMEmbedder(model: StubMiniLMModel(single: vector, batch: nil, error: nil), batchSize: 1)

    let embedded = try await embedder.embed("hello world")

    #expect(abs(embedded[0] - 0.6) < 0.000_001)
    #expect(abs(embedded[1] - 0.8) < 0.000_001)
    #expect(abs(l2Norm(embedded) - 1) < 0.000_001)
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbedderRejectsZeroMagnitudeOutputs() async throws {
    let vector = Array(repeating: Float(0), count: 384)
    let embedder = MiniLMEmbedder(model: StubMiniLMModel(single: vector, batch: nil, error: nil), batchSize: 1)

    await #expect(throws: (any Error).self) {
        _ = try await embedder.embed("hello world")
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbedderRejectsNonFiniteDirectOutputs() async throws {
    var vector = Array(repeating: Float(0), count: 384)
    vector[0] = .nan
    let embedder = MiniLMEmbedder(model: StubMiniLMModel(single: vector, batch: nil, error: nil), batchSize: 1)

    await #expect(throws: (any Error).self) {
        _ = try await embedder.embed("hello world")
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbedderRejectsNonFiniteBatchOutputs() async throws {
    var finite = Array(repeating: Float(0), count: 384)
    finite[0] = 5
    var nonFinite = Array(repeating: Float(0), count: 384)
    nonFinite[0] = .infinity
    let embedder = MiniLMEmbedder(
        model: StubMiniLMModel(single: nil, batch: [finite, nonFinite], error: nil),
        batchSize: 2
    )

    await #expect(throws: (any Error).self) {
        _ = try await embedder.embed(batch: ["finite", "bad"])
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbedderPropagatesModelPredictionErrors() async throws {
    let embedder = MiniLMEmbedder(
        model: StubMiniLMModel(single: nil, batch: nil, error: StubMiniLMError()),
        batchSize: 1
    )

    await #expect(throws: StubMiniLMError.self) {
        _ = try await embedder.embed("hello world")
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"
))
func miniLMEmbedderProducesExpectedDimensions() async throws {
    let embedder = try MiniLMEmbedder()
    let vector = try await embedder.embed("hello world")
    #expect(vector.count == embedder.dimensions)
}

@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"
))
func miniLMEmbedderBatchMatchesSingle() async throws {
    let embedder = try MiniLMEmbedder()
    let texts = ["hello world", "wax is fast"]
    let singleA = try await embedder.embed(texts[0])
    let singleB = try await embedder.embed(texts[1])
    let batch = try await embedder.embed(batch: texts)

    #expect(batch.count == texts.count)
    #expect(batch[0].count == embedder.dimensions)
    #expect(batch[1].count == embedder.dimensions)
    assertVectorsClose(batch[0], singleA, tolerance: 1e-4)
    assertVectorsClose(batch[1], singleB, tolerance: 1e-4)
}

@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"
))
func miniLMEmbedderConfigurableBatchSizeWorks() async throws {
    let config = MiniLMEmbedder.Config(batchSize: 4)
    let embedder = try MiniLMEmbedder(config: config)
    let texts = ["a", "b", "c", "d", "e"]
    let batch = try await embedder.embed(batch: texts)
    #expect(batch.count == texts.count)
    for vector in batch {
        #expect(vector.count == embedder.dimensions)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"
))
func miniLMEmbedderPrewarmDoesNotThrow() async throws {
    let embedder = try MiniLMEmbedder()
    try await embedder.prewarm()
}

#if canImport(Darwin)
/// Concurrent batch embedding keeps the prediction queue busy back to back. Before the
/// queue drained its autorelease pool per work item, CoreML outputs piled up (~17 MB per
/// 1,000 embeds) until IOSurface allocation failed and CoreML raised an uncaught NSException.
@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"
))
func miniLMEmbedderMemoryStaysFlatUnderConcurrentBatches() async throws {
    let embedder = try MiniLMEmbedder()
    let text = String(repeating: "the user moved to a new apartment near the river and adopted a cat. ", count: 20)
    func embedRounds(_ rounds: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for round in 0..<rounds {
                        let batch = (0..<32).map { "\(worker)-\(round)-\($0) \(text)" }
                        _ = try await embedder.embed(batch: batch)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    try await embedRounds(4) // warm up: 512 embeds
    let before = physicalFootprintMB()
    try await embedRounds(12) // 1,536 embeds; the leak added ~26 MB here
    let growth = physicalFootprintMB() - before
    #expect(growth < 10, "footprint grew \(growth) MB over 1,536 concurrent batch embeds")
}

private func physicalFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "task_info failed: \(result)")
    return Double(info.phys_footprint) / 1_048_576
}
#endif

private func assertVectorsClose(_ lhs: [Float], _ rhs: [Float], tolerance: Float) {
    #expect(lhs.count == rhs.count)
    for (l, r) in zip(lhs, rhs) {
        #expect(abs(l - r) <= tolerance)
    }
}

private func l2Norm(_ vector: [Float]) -> Float {
    sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
}
#endif
