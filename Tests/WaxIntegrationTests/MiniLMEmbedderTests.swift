import Testing

#if canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM

@Test func miniLMEmbedderProducesExpectedDimensions() async throws {
    let embedder = MiniLMEmbedder()
    let vector = try await embedder.embed("hello world")
    #expect(vector.count == embedder.dimensions)
}

@Test func miniLMEmbedderBatchMatchesSingle() async throws {
    let embedder = MiniLMEmbedder()
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

@Test func miniLMEmbedderConfigurableBatchSizeWorks() async throws {
    let config = MiniLMEmbedder.Config(batchSize: 4)
    let embedder = MiniLMEmbedder(config: config)
    let texts = ["a", "b", "c", "d", "e"]
    let batch = try await embedder.embed(batch: texts)
    #expect(batch.count == texts.count)
    for vector in batch {
        #expect(vector.count == embedder.dimensions)
    }
}

@Test func miniLMEmbedderPrewarmDoesNotThrow() async throws {
    let embedder = MiniLMEmbedder()
    try await embedder.prewarm()
}

private func assertVectorsClose(_ lhs: [Float], _ rhs: [Float], tolerance: Float) {
    #expect(lhs.count == rhs.count)
    for (l, r) in zip(lhs, rhs) {
        #expect(abs(l - r) <= tolerance)
    }
}
#endif
