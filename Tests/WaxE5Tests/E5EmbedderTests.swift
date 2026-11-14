#if canImport(WaxVectorSearchE5)
#if canImport(CoreML)
import CoreML
#endif
import Foundation
import Testing
import WaxVectorSearch
@_spi(Testing) @testable import WaxVectorSearchE5

/// Real inference against the bundled e5-small-v2 model: Core ML on Apple platforms,
/// WaxMILRuntime elsewhere. Guarded by WAX_TEST_E5=1, like the Arctic and MiniLM inference suites.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_E5"] != "1",
                 "Set WAX_TEST_E5=1 to run e5 embedder tests"))
struct E5EmbedderTests {
    struct ReferenceRow: Decodable {
        /// `query` rows are embedded with `embedQuery`, `passage` rows with `embed`.
        let role: String
        let text: String
        let tokens: Int
        let embedding: [Float]
    }

    struct Reference: Decodable {
        let rows: [ReferenceRow]
    }

    /// PyTorch `intfloat/e5-small-v2` masked mean pooling + L2 norm of each row's text with its
    /// role's prefix, `"query: "` or `"passage: "`.
    static func reference() throws -> Reference {
        let url = try #require(Bundle.module.url(forResource: "e5_reference_embeddings", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    @Test
    func producesFiniteUnitVectorsOf384Dimensions() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try E5Embedder()
        #expect(embedder.dimensions == 384)
        #expect(embedder.normalize == false)
        let vectors = try await embedder.embed(batch: ["finite check", "second sentence", "third one"])
        #expect(vectors.count == 3)
        for vector in vectors {
            #expect(vector.count == 384)
            let finite = vector.allSatisfy(\.isFinite)
            #expect(finite)
            let magnitude = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            #expect(abs(magnitude - 1) < 1e-3, "expected a unit vector, got magnitude \(magnitude)")
        }
    }

    @Test
    func identityNamesPrefixedE5SmallV2() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let identity = try E5Embedder().identity
        #expect(identity?.provider == "Wax")
        #expect(identity?.model == "E5SmallV2-prefixed")
        #expect(identity?.dimensions == 384)
        #expect(identity?.normalized == true)
    }

    @Test
    func matchesPyTorchMeanPoolingThroughWaxTokenizer() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try E5Embedder()
        let rows = try Self.reference().rows
        let passages = rows.filter { $0.role == "passage" }
        #expect(passages.contains { $0.tokens == 512 }, "fixture must cover the 512-token maximum")
        #expect(rows.contains { $0.role == "query" }, "fixture must cover the query prefix")
        for row in rows {
            let vector = row.role == "query"
                ? try await embedder.embedQuery(row.text)
                : try await embedder.embed(row.text)
            let similarity = Self.cosine(vector, row.embedding)
            #expect(similarity >= 0.999, "\(row.role), \(row.tokens) tokens: cosine \(similarity) to PyTorch")
        }
        let batched = try await embedder.embed(batch: passages.map(\.text))
        for (vector, row) in zip(batched, passages) {
            let similarity = Self.cosine(vector, row.embedding)
            #expect(similarity >= 0.999, "padded batch, \(row.tokens)-token text: cosine \(similarity) to PyTorch")
        }
    }

    @Test
    func embeddingIsDeterministic() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try E5Embedder()
        let text = "Swift is a programming language developed by Apple."
        let first = try await embedder.embed(text)
        let second = try await embedder.embed(text)
        #expect(first == second)
    }

    /// e5 was trained with `"query: "` on queries and `"passage: "` on documents. Each embedder
    /// path must feed the model exactly one of those prefixes, never both and never none.
    @Test
    func queriesUseQueryPrefixAndDocumentsUsePassagePrefix() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let model = try E5Embeddings()
        let embedder = E5Embedder(model: model)
        let text = "Swift is a programming language developed by Apple."
        let other = "Wax keeps agent memory searchable in a single local file."

        let expectedQuery = try #require(try await model.encode(sentence: "query: " + text))
        let expectedPassage = try #require(try await model.encode(sentence: "passage: " + text))
        let expectedBatch = try #require(
            try await model.encode(batch: ["passage: " + text, "passage: " + other])
        )

        #expect(try await embedder.embedQuery(text) == expectedQuery)
        #expect(try await embedder.embed(text) == expectedPassage)
        #expect(try await embedder.embed(batch: [text]) == [expectedPassage])
        #expect(try await embedder.embed(batch: [text, other]) == expectedBatch)
        #expect(expectedQuery != expectedPassage)
    }

    @Test
    func relatedTextRanksAboveUnrelatedText() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try E5Embedder()
        let query = try await embedder.embedQuery("What degree did I graduate with?")
        let related = try await embedder.embed(
            "I graduated with a Bachelor's degree in Business Administration from the state university."
        )
        let unrelated = try await embedder.embed(
            "The farmer needs to transport a fox, a chicken, and some grain across a river using a boat."
        )
        #expect(Self.cosine(query, related) > Self.cosine(query, unrelated) + 0.05)
    }

    /// CPU only, the default. A GPU load of this range-shaped graph spends many minutes in
    /// MPSGraph shape specialization, so the GPU fallback is not exercised here.
    @Test
    func paddedBatchMatchesSingleRows() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try E5Embedder()
        let texts = [
            "short note",
            Array(repeating: "Wax keeps agent memory searchable in a single local file.", count: 6)
                .joined(separator: " "),
        ]
        let batch = try await embedder.embed(batch: texts)
        for (text, row) in zip(texts, batch) {
            let finite = row.allSatisfy(\.isFinite)
            #expect(finite)
            let single = try await embedder.embed(text)
            let similarity = Self.cosine(single, row)
            #expect(similarity >= 0.999, "padded row cosine \(similarity) to single")
        }
    }

    #if canImport(CoreML)
    @Test
    func predictionErrorsPropagateInsteadOfBecomingNil() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let model = try E5Embeddings()
        // The model accepts sequence lengths 32...512; 16 is outside the flexible shape range.
        let inputIds = try MLMultiArray(shape: [1, 16], dataType: .int32)
        let attentionMask = try MLMultiArray(shape: [1, 16], dataType: .int32)
        await #expect(throws: (any Error).self) {
            _ = try await model._predictForTesting(inputIds: inputIds, attentionMask: attentionMask, batchSize: 1)
        }
    }

    @Test
    func defaultsToCPUComputeUnits() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        #expect(try E5Embeddings().computeUnits == .cpuOnly)
    }
    #endif
}
#endif
