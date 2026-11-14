#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import Foundation
import Testing
@testable import WaxVectorSearchMiniLM

/// Platforms without Core ML run the same bundled MiniLM graph on WaxMILRuntime and record the
/// same identity, so a store written on one runtime is searched with vectors from the other.
/// Both runtimes must embed the same text to the same direction.
///
/// The weights are FP32 in both runtimes; Core ML may compute in FP16 on the Neural Engine.
/// Cosine is scale-invariant, so the Core ML embedder's L2 normalisation does not matter here.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
                 "Set WAX_TEST_MINILM=1 to compare MiniLM on Core ML and WaxMILRuntime"))
struct MiniLMRuntimeParityTests {
    static let minimumCosine = 0.999

    @Test func coreMLAndWaxMILRuntimeEmbedTheSameDirection() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let coreML = try MiniLMEmbedder()
        let mil = try MiniLMMILEmbeddings()
        for text in RuntimeParityTexts.all {
            let expected = try await coreML.embed(text)
            let actual = try #require(try await mil.encode(sentence: text))
            let similarity = runtimeParityCosine(expected, actual)
            #expect(similarity >= Self.minimumCosine, "cosine \(similarity) for '\(text.prefix(40))'")
        }
        let batch = try #require(try await mil.encode(batch: RuntimeParityTexts.all))
        for (text, actual) in zip(RuntimeParityTexts.all, batch) {
            let similarity = runtimeParityCosine(try await coreML.embed(text), actual)
            #expect(similarity >= Self.minimumCosine, "padded batch: cosine \(similarity) for '\(text.prefix(40))'")
        }
    }
}

enum RuntimeParityTexts {
    static let all = [
        "The user's favorite beverage is oolong tea.",
        "What does the person like to drink?",
        "Swift concurrency makes structured parallelism practical.",
        // Over 256 WordPiece tokens: both runtimes must truncate at the same token.
        Array(repeating: "Wax keeps agent memory searchable in a single local file.", count: 40)
            .joined(separator: " "),
    ]
}

func runtimeParityCosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, normA = 0.0, normB = 0.0
    for (x, y) in zip(a, b) {
        dot += Double(x) * Double(y)
        normA += Double(x) * Double(x)
        normB += Double(y) * Double(y)
    }
    return dot / (normA.squareRoot() * normB.squareRoot())
}
#endif
