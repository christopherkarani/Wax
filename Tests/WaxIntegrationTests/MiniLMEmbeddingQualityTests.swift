#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
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

private struct MiniLMModelMetadata: Decodable {
    let storagePrecision: String
    let computePrecision: String
    let userDefinedMetadata: [String: String]
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

private enum MiniLMAssetLoader {
    static func modelDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WaxVectorSearchMiniLM/Resources/all-MiniLM-L6-v2.mlmodelc")
    }

    static func modelMIL() throws -> String {
        try String(
            contentsOf: modelDirectory().appendingPathComponent("model.mil"),
            encoding: .utf8
        )
    }

    static func metadata() throws -> MiniLMModelMetadata {
        let data = try Data(contentsOf: modelDirectory().appendingPathComponent("metadata.json"))
        let entries = try JSONDecoder().decode([MiniLMModelMetadata].self, from: data)
        guard let metadata = entries.first else {
            throw TestingError("Missing MiniLM model metadata")
        }
        return metadata
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

@Test func minilmBundledModelDoesNotUseKnownBadW8A8Quantization() throws {
    let mil = try MiniLMAssetLoader.modelMIL()
    let metadata = try MiniLMAssetLoader.metadata()

    #expect(metadata.storagePrecision.contains("Float32"))
    #expect(metadata.computePrecision.contains("Float32"))
    #expect(!metadata.computePrecision.contains("Float16"))

    #expect(
        !mil.contains("constexpr_blockwise_shift_scale"),
        "MiniLM model must not use the W8A8 constexpr blockwise quantization path that produced NaN embeddings on macOS 26.3."
    )
    #expect(
        !mil.contains("fp16(nan)"),
        "MiniLM model must not contain NaN quantization scales."
    )
    #expect(
        !mil.contains("pooler"),
        "MiniLM must return mean-pooled token embeddings, not the BERT pooler output (#257)."
    )
    #expect(mil.contains("-> (embeddings)"), "MiniLM Core ML output must be named `embeddings`.")
    #expect(metadata.userDefinedMetadata["wax.minilm.pooling"] == "mean")
    #expect(metadata.userDefinedMetadata["wax.minilm.max_seq_length"] == "256")
    #expect(
        !mil.contains("-0x1.fffffep+127"),
        "Attention mask fill must stay finite in Float16 (-FLT_MAX becomes -inf on the Neural Engine)."
    )
}

@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM inference quality tests"
))
func minilmEmbeddingsStayCloseToBaseline() async throws {
    let fixture = try BaselineFixtureLoader.load()
    #expect(fixture.dimensions == 384)
    #expect(!fixture.sentences.isEmpty)
    #expect(fixture.sentences.count == fixture.embeddings.count)

    // At least one sentence must exceed the 256-token reference limit so truncation is covered.
    let tokenizer = try BertTokenizer()
    let longest = try fixture.sentences.map { try tokenizer.tokenizeToIds(text: $0).count }.max() ?? 0
    #expect(longest > 256)

    let embedder = try MiniLMEmbedder()
    let freshEmbeddings = try await embedder.embed(batch: fixture.sentences)
    #expect(freshEmbeddings.count == fixture.embeddings.count)

    var similarities: [Float] = []
    similarities.reserveCapacity(fixture.embeddings.count)

    for (baseline, fresh) in zip(fixture.embeddings, freshEmbeddings) {
        #expect(baseline.count == fresh.count)
        similarities.append(cosineSimilarity(baseline, fresh))
    }

    let average = similarities.reduce(0, +) / Float(similarities.count)
    let minimum = similarities.min() ?? 0

    // The fixture holds sentence-transformers all-MiniLM-L6-v2 reference vectors
    // (masked mean pooling + L2 normalize, computed in PyTorch), so this checks the
    // whole Swift pipeline (tokenizer, Core ML graph, decode) against the reference.
    // A model that returns the BERT pooler (CLS -> dense -> tanh) scores ~0 here (#257).
    #expect(average >= 0.99, "Average cosine similarity was \(average)")
    #expect(minimum >= 0.98, "Minimum cosine similarity was \(minimum)")
}

// The fixture is generated from the PyTorch reference, never from Wax's own output:
//   python Resources/scripts/models/generate_minilm_fixture.py \
//     Tests/WaxIntegrationTests/Fixtures/minilm_baseline_embeddings.json

@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM inference quality tests"
))
func minilmMatchesPublishedSentenceTransformersAnchor() async throws {
    // Published sentence-transformers/all-MiniLM-L6-v2 output for this sentence (first 8 dims).
    let published: [Float] = [0.067657, 0.063496, 0.048713, 0.079305, 0.037448, 0.002653, 0.039375, -0.007098]
    let embedder = try MiniLMEmbedder()
    let vector = try await embedder.embed("This is an example sentence")
    #expect(vector.count == 384)
    for (index, expected) in published.enumerated() {
        #expect(abs(vector[index] - expected) < 1e-4, "dim \(index): \(vector[index]) vs \(expected)")
    }
}
#endif
