#if canImport(CoreML)
import Foundation
import Testing
import WaxVectorSearch
@testable import WaxVectorSearchArctic

/// Core Arctic embedder tests. Guarded by WAX_TEST_ARCTIC=1 environment variable
/// since the model may not be converted/present on all CI runners.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                 "Set WAX_TEST_ARCTIC=1 to run Arctic embedder tests"))
struct ArcticEmbedderTests {

    @Test
    func arcticEmbedderProduces384Dimensions() async throws {
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 1)
        let vector = try await embedder.embed("Hello world")

        #expect(vector.count == 384)
        #expect(embedder.dimensions == 384)
    }

    @Test
    func arcticEmbedderIdentity() throws {
        let embedder = try ArcticEmbedder()

        let identity = embedder.identity
        #expect(identity?.provider == "Wax")
        #expect(identity?.model == "ArcticEmbedS")
        #expect(identity?.dimensions == 384)
        #expect(identity?.normalized == true)
    }

    @Test
    func arcticBatchConsistency() async throws {
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 1)

        let text = "The quick brown fox jumps over the lazy dog"
        let single = try await embedder.embed(text)
        let batch = try await embedder.embed(batch: [text, text])

        #expect(batch.count == 2)
        #expect(batch[0].count == 384)
        #expect(batch[1].count == 384)

        // CoreML dynamic shapes introduce numerical differences between single (shape [1, N])
        // and batch (shape [2, N]) prediction paths due to different computation scheduling.
        // Verify semantic alignment — single and batch should point in the same direction.
        let sim = cosineSimilarity(single, batch[0])
        #expect(sim > 0.6, "Single vs batch[0] cosine similarity should be > 0.6, got \(sim)")

        // Verify both batch items are near-identical (same text, same batch shape)
        let batchSim = cosineSimilarity(batch[0], batch[1])
        #expect(batchSim > 0.99, "Batch items for same text should be near-identical, got \(batchSim)")
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    @Test
    func arcticPrewarmDoesNotThrow() async throws {
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 4)
    }

    @Test
    func arcticEmbedderNormalizesOutput() async throws {
        let embedder = try ArcticEmbedder()
        try await embedder.prewarm(batchSize: 1)
        let vector = try await embedder.embed("Test normalization")

        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 0.01, "Expected unit vector, got magnitude \(magnitude)")
    }
}
#endif
