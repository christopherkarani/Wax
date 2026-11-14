#if canImport(WaxRerankerMiniLM) && canImport(CoreML)
import CoreML
import Foundation
import Testing
import WaxBertTokenizer
@testable import WaxRerankerMiniLM

/// Platforms without Core ML score with the same bundled reranker graph on WaxMILRuntime. Both
/// runtimes must give the same windows, and so the same documents, the same logits.
///
/// Tolerance: both share the INT8 weights. Against PyTorch fp32 over the reference windows,
/// Core ML on the CPU (FP16 compute) measured max |d| 0.084 logits and WaxMILRuntime (FP32
/// compute) 0.018, so the two differ by at most ~0.10; 0.12 adds a little margin on logits that
/// span about -11.5 to 8.6.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_RERANKER"] != "1",
                 "Set WAX_TEST_RERANKER=1 to compare the reranker on Core ML and WaxMILRuntime"))
struct MiniLMRerankerRuntimeParityTests {
    static let tolerance: Float = 0.12

    @available(macOS 15.0, iOS 18.0, *)
    @Test func coreMLAndWaxMILRuntimeScoreTheSameWindows() async throws {
        let coreML = try MiniLMRerankerModel.bundled(computeUnits: .cpuOnly)
        let mil = try MiniLMRerankerMILModel.bundled()
        let tokenizer = try BertTokenizer()
        for item in try RerankerReference.load().cases {
            let rows = try MiniLMReranker.windows(
                query: item.query,
                documents: item.documents,
                tokenizer: tokenizer,
                windowing: MiniLMReranker.defaultWindowing
            )
            for row in rows {
                let length = MiniLMRerankerModel.bucket(for: row.inputIds.count)
                let expected = try await coreML.scores(rows: [row], sequenceLength: length)
                let actual = try await mil.scores(rows: [row], sequenceLength: length)
                #expect(abs(expected[0] - actual[0]) < Self.tolerance, "\(item.query): \(expected[0]) vs \(actual[0])")
            }

            // A document scores its best window, so each document's score agrees as closely.
            let coreMLScores = try await MiniLMReranker(model: coreML, tokenizer: tokenizer)
                .scores(query: item.query, documents: item.documents)
            var milScores = [Float](repeating: -.infinity, count: item.documents.count)
            for row in rows {
                let score = try await mil.scores(rows: [row], sequenceLength: row.inputIds.count)[0]
                milScores[row.documentIndex] = max(milScores[row.documentIndex], score)
            }
            for (expected, actual) in zip(coreMLScores, milScores) {
                #expect(abs(expected - actual) < Self.tolerance, "\(item.query): document \(expected) vs \(actual)")
            }
        }
    }
}
#endif
