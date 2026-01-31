#if canImport(WaxVectorSearchMiniLM)
import Foundation
import Testing
import WaxVectorSearchMiniLM

private struct BaselineEmbeddingFixture: Codable {
    let sentences: [String]
    let embeddings: [[Float]]
    let dimensions: Int
}

private struct TestingError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

private enum BaselineFixtureLoader {
    static func url() throws -> URL {
        guard let url = Bundle.module.url(forResource: "minilm_baseline_embeddings", withExtension: "json") else {
            throw TestingError("Missing baseline fixture: minilm_baseline_embeddings.json")
        }
        return url
    }

    static func load() throws -> BaselineEmbeddingFixture {
        let url = try url()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BaselineEmbeddingFixture.self, from: data)
    }
}

private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
    var dot: Float = 0
    var lhsNorm: Float = 0
    var rhsNorm: Float = 0

    for index in 0..<lhs.count {
        let a = lhs[index]
        let b = rhs[index]
        dot += a * b
        lhsNorm += a * a
        rhsNorm += b * b
    }

    let denom = (sqrt(lhsNorm) * sqrt(rhsNorm))
    return denom == 0 ? 0 : (dot / denom)
}

@Test func minilmEmbeddingsStayCloseToBaseline() async throws {
    let fixture = try BaselineFixtureLoader.load()
    #expect(fixture.dimensions == 384)
    #expect(!fixture.sentences.isEmpty)
    #expect(fixture.sentences.count == fixture.embeddings.count)

    let model = MiniLMEmbeddings()
    guard let freshEmbeddings = await model.encode(batch: fixture.sentences) else {
        throw TestingError("MiniLM produced no embeddings")
    }
    #expect(freshEmbeddings.count == fixture.embeddings.count)

    var similarities: [Float] = []
    similarities.reserveCapacity(fixture.embeddings.count)

    for (baseline, fresh) in zip(fixture.embeddings, freshEmbeddings) {
        #expect(baseline.count == fresh.count)
        similarities.append(cosineSimilarity(baseline, fresh))
    }

    let average = similarities.reduce(0, +) / Float(similarities.count)
    let minimum = similarities.min() ?? 0

    #expect(average >= 0.98, "Average cosine similarity was \(average)")
    #expect(minimum >= 0.95, "Minimum cosine similarity was \(minimum)")
}

@Test func generateMiniLMBaselineFixture() async throws {
    guard ProcessInfo.processInfo.environment["WAX_GENERATE_MINILM_FIXTURES"] == "1" else {
        return
    }

    let sentences = [
        "Swift concurrency makes structured parallelism practical.",
        "Vector search underpins modern retrieval-augmented generation.",
        "Core ML optimizations should balance accuracy and throughput.",
        "Batch embeddings improve ANE utilization on Apple silicon.",
        "Memory systems need fast ingestion and recall latencies.",
        "Structured logging helps debug RAG pipelines.",
        "Compression techniques like quantization reduce bandwidth.",
        "On-device inference keeps user data private."
    ]

    let model = MiniLMEmbeddings()
    guard let embeddings = await model.encode(batch: sentences) else {
        throw TestingError("MiniLM produced no embeddings")
    }

    let fixture = BaselineEmbeddingFixture(
        sentences: sentences,
        embeddings: embeddings,
        dimensions: 384
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(fixture)

    let fileURL = URL(fileURLWithPath: #filePath)
    let fixturesDir = fileURL.deletingLastPathComponent().appendingPathComponent("Fixtures")
    try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    try data.write(to: fixturesDir.appendingPathComponent("minilm_baseline_embeddings.json"), options: .atomic)
}
#endif
