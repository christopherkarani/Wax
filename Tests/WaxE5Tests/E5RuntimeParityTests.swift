#if canImport(WaxVectorSearchE5) && canImport(CoreML)
import Foundation
import Testing
@testable import WaxVectorSearchE5

/// Platforms without Core ML run the same bundled e5 graph on WaxMILRuntime and record the same
/// identity, so both runtimes must embed the same text to the same direction.
///
/// Threshold: both runtimes use the same INT8 weights, so they share the quantisation error and
/// differ only in activation precision (Core ML FP16, WaxMILRuntime FP32). Against PyTorch fp32,
/// the Core ML suite pins >= 0.999 and WaxMILRuntime measured >= 0.99986; their angles add to
/// at most ~3.96 degrees (cosine 0.9976) even if the errors were unrelated. 0.998 sits just
/// above that worst case and still keeps the two vector spaces interchangeable for retrieval.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_E5"] != "1",
                 "Set WAX_TEST_E5=1 to compare e5 on Core ML and WaxMILRuntime"))
struct E5RuntimeParityTests {
    static let minimumCosine = 0.998

    static let texts = [
        "Swift is a programming language developed by Apple.",
        "I graduated with a Bachelor's degree in Business Administration from the state university.",
        Array(repeating: "Wax keeps agent memory searchable in a single local file.", count: 60)
            .joined(separator: " "),
    ]

    @Test func coreMLAndWaxMILRuntimeEmbedTheSameDirection() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let coreML = try E5Embedder()
        let mil = try E5MILEmbeddings()
        for text in Self.texts {
            // The embedder adds e5's prefixes; the MIL model encodes text as given.
            let passage = try #require(try await mil.encode(sentence: "passage: " + text))
            let query = try #require(try await mil.encode(sentence: "query: " + text))
            let passageCosine = Self.cosine(try await coreML.embed(text), passage)
            let queryCosine = Self.cosine(try await coreML.embedQuery(text), query)
            #expect(passageCosine >= Self.minimumCosine, "passage cosine \(passageCosine) for '\(text.prefix(40))'")
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
