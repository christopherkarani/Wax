#if canImport(WaxVectorSearchArctic) && canImport(CoreML)
import Foundation
import Testing
@testable import WaxVectorSearchArctic

/// Platforms without Core ML run the same bundled Arctic graph on WaxMILRuntime and record the
/// same identity, so both runtimes must embed the same text to the same direction.
///
/// Threshold: as for e5 (`E5RuntimeParityTests`), both runtimes share the INT8 weights and differ
/// only in activation precision (Core ML FP16, WaxMILRuntime FP32). There is no PyTorch fixture
/// for Arctic; WaxMILRuntime matches an independent NumPy forward pass on these weights to
/// >= 0.99999, so the bound is set to e5's 0.998.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                 "Set WAX_TEST_ARCTIC=1 to compare Arctic on Core ML and WaxMILRuntime"))
struct ArcticRuntimeParityTests {
    static let minimumCosine = 0.998
    static let queryPrefix = "Represent this sentence for searching relevant passages: "

    static let texts = [
        "Regular physical activity improves cardiovascular health, strengthens muscles, and boosts mental well-being.",
        "What are the benefits of exercise?",
        Array(repeating: "Wax keeps agent memory searchable in a single local file.", count: 60)
            .joined(separator: " "),
    ]

    @Test func coreMLAndWaxMILRuntimeEmbedTheSameDirection() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let coreML = try ArcticEmbedder()
        let mil = try ArcticMILEmbeddings()
        for text in Self.texts {
            // Documents are embedded as given; the embedder adds the query prefix to queries.
            let document = try #require(try await mil.encode(sentence: text))
            let query = try #require(try await mil.encode(sentence: Self.queryPrefix + text))
            let documentCosine = Self.cosine(try await coreML.embed(text), document)
            let queryCosine = Self.cosine(try await coreML.embedQuery(text), query)
            #expect(documentCosine >= Self.minimumCosine, "document cosine \(documentCosine) for '\(text.prefix(40))'")
            #expect(queryCosine >= Self.minimumCosine, "query cosine \(queryCosine) for '\(text.prefix(40))'")
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, normA = 0.0, normB = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            normA += Double(x) * Double(x)
            normB += Double(y) * Double(y)
        }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
#endif
