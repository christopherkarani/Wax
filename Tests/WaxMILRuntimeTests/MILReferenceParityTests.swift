import Foundation
import Testing
import WaxMILRuntime

/// Golden outputs for fixed token ids (see `provenance` in the fixture):
/// - `pytorch`: the original Hugging Face checkpoints in PyTorch fp32, copied from the repo's
///   existing Core ML parity fixtures. Measures interpreter plus weight quantisation.
/// - `numpy`: an independent float64 NumPy BERT over the bundled (dequantised) weights.
///   Measures the interpreter alone.
/// No PyTorch reference exists in the repo for Arctic, so it is checked against NumPy only.
struct MILReference: Decodable {
    struct EmbeddingCase: Decodable {
        let text: String
        let inputIDs: [Int32]
        let pytorch: [Float]?
        let numpy: [Float]
    }

    struct EmbeddingModel: Decodable {
        let cases: [EmbeddingCase]
    }

    struct RerankerCase: Decodable {
        let inputIDs: [Int32]
        let tokenTypeIDs: [Int32]
        let pytorch: Float
        let numpy: Float
    }

    struct RerankerModel: Decodable {
        let cases: [RerankerCase]
    }

    struct Models: Decodable {
        let minilm: EmbeddingModel
        let e5: EmbeddingModel
        let arctic: EmbeddingModel
        let reranker: RerankerModel
    }

    let models: Models

    static func load() throws -> MILReference {
        let url = try #require(Bundle.module.url(forResource: "mil_reference_vectors", withExtension: "json"))
        return try JSONDecoder().decode(MILReference.self, from: Data(contentsOf: url))
    }
}

struct MILReferenceParityTests {
    /// Minimum cosine similarity to PyTorch fp32, per model. MiniLM ships fp32 weights (measured
    /// 1.0000000). e5's weights are int8 with fp16 scales, so its bound reflects quantisation:
    /// measured 0.99986–0.99989, the same as NumPy on those int8 weights.
    static let pytorchCosine: [BundledModel: Double] = [.miniLM: 0.999_999, .e5: 0.999_7]
    /// Minimum cosine similarity to NumPy on the identical weights (measured >= 0.9999999).
    static let numpyCosine = 0.999_99
    /// Reranker logits (about -11.5 to 8.6). Measured: within 0.018 of PyTorch (as is NumPy on the
    /// same int8 weights) and within 4e-4 of NumPy.
    static let rerankerPytorchTolerance: Float = 0.05
    static let rerankerNumpyTolerance: Float = 2e-3

    static func embed(_ model: BundledModel, _ ids: [Int32]) throws -> [Float] {
        let outputs = try model.model.predict(inputIDs: [ids], attentionMask: [[Int32](repeating: 1, count: ids.count)])
        let output = try #require(outputs[model.outputName])
        #expect(output.shape == [1, 384])
        return output.values
    }

    @Test(arguments: [BundledModel.miniLM, .e5, .arctic])
    func embeddingsMatchTheReferences(model: BundledModel) throws {
        let reference = try MILReference.load()
        let cases = switch model {
        case .miniLM: reference.models.minilm.cases
        case .e5: reference.models.e5.cases
        default: reference.models.arctic.cases
        }
        #expect(!cases.isEmpty)
        for item in cases {
            let vector = try Self.embed(model, item.inputIDs)
            let toNumpy = cosine(vector, item.numpy)
            #expect(toNumpy >= Self.numpyCosine, "\(model) '\(item.text)': cosine to NumPy \(toNumpy)")
            if let pytorch = item.pytorch, let bound = Self.pytorchCosine[model] {
                let toPytorch = cosine(vector, pytorch)
                #expect(toPytorch >= bound, "\(model) '\(item.text)': cosine to PyTorch \(toPytorch)")
            }
        }
    }

    /// Every window that is its document's only window (11 to 280 tokens), so its PyTorch
    /// document score is that window's logit.
    @Test func rerankerScoresMatchTheReferences() throws {
        let cases = try MILReference.load().models.reranker.cases
        #expect(cases.count == 8)
        let model = try BundledModel.reranker.model
        for item in cases {
            let outputs = try model.predict(
                inputIDs: [item.inputIDs],
                attentionMask: [[Int32](repeating: 1, count: item.inputIDs.count)],
                tokenTypeIDs: [item.tokenTypeIDs]
            )
            let score = try #require(outputs["scores"]?.values.first)
            #expect(abs(score - item.numpy) <= Self.rerankerNumpyTolerance, "\(item.inputIDs.count) tokens: \(score) vs NumPy \(item.numpy)")
            #expect(abs(score - item.pytorch) <= Self.rerankerPytorchTolerance, "\(item.inputIDs.count) tokens: \(score) vs PyTorch \(item.pytorch)")
        }
    }
}
