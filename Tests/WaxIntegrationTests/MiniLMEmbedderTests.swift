import Foundation
import Testing

#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM

private func isMiniLMInferenceEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] == "1"
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMEmbedderProducesExpectedDimensions() async throws {
    guard isMiniLMInferenceEnabled() else { return }
    let embedder = try MiniLMEmbedder()
    let vector = try await embedder.embed("hello world")
    #expect(vector.count == embedder.dimensions)
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMEmbedderBatchMatchesSingle() async throws {
    guard isMiniLMInferenceEnabled() else { return }
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
@Test func miniLMEmbedderConfigurableBatchSizeWorks() async throws {
    guard isMiniLMInferenceEnabled() else { return }
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
@Test func miniLMEmbedderPrewarmDoesNotThrow() async throws {
    guard isMiniLMInferenceEnabled() else { return }
    let embedder = try MiniLMEmbedder()
    try await embedder.prewarm()
}

private func assertVectorsClose(_ lhs: [Float], _ rhs: [Float], tolerance: Float) {
    #expect(lhs.count == rhs.count)
    for (l, r) in zip(lhs, rhs) {
        #expect(abs(l - r) <= tolerance)
    }
}
#endif
