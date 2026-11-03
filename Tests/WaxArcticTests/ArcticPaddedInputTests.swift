#if canImport(CoreML)
import CoreML
import Foundation
import Testing
@testable import WaxVectorSearchArctic

/// A batch mixing a short and a long sentence pads the short row with mask zeros. A model
/// converted with Hugging Face's `finfo(float32).min` mask fill turns that fill into -inf when
/// the Neural Engine runs in Float16, and `0 * -inf` makes the padded batch NaN.
/// `scripts/convert_arctic_embed.py` uses a finite `-1e4` fill instead.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                 "Set WAX_TEST_ARCTIC=1 to run Arctic embedder tests"))
struct ArcticPaddedInputTests {
    static let sentences = [
        "short note",
        Array(repeating: "Wax keeps agent memory searchable in a single local file.", count: 6)
            .joined(separator: " "),
    ]

    @Test(arguments: [MLComputeUnits.cpuOnly, .cpuAndNeuralEngine, .all])
    func arcticPaddedBatchEmbeddingsAreFinite(units: MLComputeUnits) async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let model = try ArcticEmbeddings(configuration: configuration)
        let rows = try await model.encode(batch: Self.sentences) ?? []
        #expect(rows.count == Self.sentences.count)
        for (index, row) in rows.enumerated() {
            #expect(row.count == 384)
            let nonFinite = row.filter { !$0.isFinite }.count
            #expect(nonFinite == 0, "row \(index) on computeUnits \(units.rawValue): \(nonFinite) NaN/inf values")
        }
    }
}
#endif
