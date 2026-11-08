import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
import WaxBertTokenizer
import WaxCore

/// The bundled `cross-encoder/ms-marco-MiniLM-L-6-v2` CoreML graph: token ids, attention mask and
/// segment ids in, one relevance logit per row out.
@available(macOS 15.0, iOS 18.0, *)
package final class MiniLMRerankerModel: @unchecked Sendable {
    package enum LoadError: LocalizedError, Sendable, Equatable {
        case missingModelResource
        case modelLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                "Could not find the ms-marco-MiniLM-L-6-v2 Core ML model in the WaxRerankerMiniLM bundle."
            case .modelLoadFailed(let details):
                "Failed to load the ms-marco-MiniLM-L-6-v2 Core ML model: \(details)"
            }
        }
    }

    /// The Core ML output was not a finite `[batch, 1]` score tensor.
    package enum OutputError: LocalizedError, Sendable, Equatable {
        case missingOutput
        case unsupportedDataType(rawValue: Int)
        case unexpectedShape(shape: [Int], batchSize: Int)
        case nonFiniteValue

        package var errorDescription: String? {
            switch self {
            case .missingOutput:
                "Reranker Core ML prediction has no multi-array output named 'scores'."
            case .unsupportedDataType(let rawValue):
                "Reranker Core ML output has unsupported data type \(rawValue); expected Float32."
            case .unexpectedShape(let shape, let batchSize):
                "Reranker Core ML output shape \(shape) does not hold one score for each of \(batchSize) rows."
            case .nonFiniteValue:
                "Reranker Core ML output contains a non-finite value."
            }
        }
    }

    /// Row lengths the converted graph accepts are 32...512 (scripts/convert_ms_marco_minilm_reranker.py).
    /// Each batch is padded up to one of these, so only a few shapes are ever planned.
    package static let sequenceLengthBuckets = [32, 64, 128, 192, 256, 288, 384, 512]
    /// The converted graph's batch upper bound.
    package static let maximumPredictionBatchSize = 64

    /// CoreML prediction is synchronous and can block for a while on a new shape. It runs on a
    /// dedicated non-cooperative queue, as the embedders' predictions do, so it never ties up
    /// the Swift concurrency pool. `.workItem` drains CoreML's autoreleased outputs after
    /// every prediction.
    private static let predictionQueue = DispatchQueue(
        label: "wax.reranker.minilm.coreml-prediction",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    package let model: MLModel

    package init(model: MLModel) {
        self.model = model
    }

    package var computeUnits: MLComputeUnits {
        model.configuration.computeUnits
    }

    /// The bundled model, loaded once per compute-unit configuration for the process.
    package static func bundled(computeUnits: MLComputeUnits) throws -> MiniLMRerankerModel {
        try cache.value(for: computeUnits) {
            let bundle = WaxBundleResolver.resolveModule(
                named: "Wax_WaxRerankerMiniLM.bundle",
                moduleFallback: .module
            )
            guard let url = bundle.url(forResource: "ms-marco-MiniLM-L-6-v2", withExtension: "mlmodelc") else {
                throw LoadError.missingModelResource
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            do {
                return MiniLMRerankerModel(model: try MLModel(contentsOf: url, configuration: configuration))
            } catch {
                throw LoadError.modelLoadFailed(error.localizedDescription)
            }
        }
    }

    private static let cache = KeyedLoadCache<MLComputeUnits, MiniLMRerankerModel>()

    /// Scores `rows` in one prediction. Every row is padded to `sequenceLength`.
    package func scores(rows: [CrossEncoderWindow], sequenceLength: Int) async throws -> [Float] {
        guard !rows.isEmpty else { return [] }
        let inputs = try Self.inputs(rows: rows, sequenceLength: sequenceLength)
        let model = self.model
        return try await withCheckedThrowingContinuation { continuation in
            Self.predictionQueue.async {
                do {
                    let output = try model.prediction(from: inputs)
                    guard let scores = output.featureValue(for: "scores")?.multiArrayValue else {
                        throw OutputError.missingOutput
                    }
                    continuation.resume(returning: try Self.decode(scores, batchSize: rows.count))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The smallest bucket that holds `length` tokens.
    package static func bucket(for length: Int) -> Int {
        sequenceLengthBuckets.first { $0 >= length } ?? sequenceLengthBuckets[sequenceLengthBuckets.count - 1]
    }

    static func inputs(rows: [CrossEncoderWindow], sequenceLength: Int) throws -> MLDictionaryFeatureProvider {
        let shape = [NSNumber(value: rows.count), NSNumber(value: sequenceLength)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        let types = try MLMultiArray(shape: shape, dataType: .int32)
        let count = rows.count * sequenceLength
        let idPointer = ids.dataPointer.bindMemory(to: Int32.self, capacity: count)
        let maskPointer = mask.dataPointer.bindMemory(to: Int32.self, capacity: count)
        let typePointer = types.dataPointer.bindMemory(to: Int32.self, capacity: count)
        idPointer.initialize(repeating: 0, count: count)
        maskPointer.initialize(repeating: 0, count: count)
        typePointer.initialize(repeating: 0, count: count)
        for (row, window) in rows.enumerated() {
            let base = row * sequenceLength
            let length = min(window.inputIds.count, sequenceLength)
            for column in 0..<length {
                idPointer[base + column] = window.inputIds[column]
                maskPointer[base + column] = 1
                typePointer[base + column] = window.tokenTypeIds[column]
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
            "token_type_ids": MLFeatureValue(multiArray: types),
        ])
    }

    /// Reads one score per row from a `[batch, 1]` or `[batch]` tensor.
    static func decode(_ scores: MLMultiArray, batchSize: Int) throws -> [Float] {
        let shape = scores.shape.map(\.intValue)
        let strides = scores.strides.map(\.intValue)
        let rowStride: Int
        switch shape.count {
        case 1 where shape[0] == batchSize:
            rowStride = strides[0]
        case 2 where shape[0] == batchSize && shape[1] == 1:
            rowStride = strides[0]
        default:
            throw OutputError.unexpectedShape(shape: shape, batchSize: batchSize)
        }
        // The graph computes in FP32 (scripts/convert_ms_marco_minilm_reranker.py).
        guard scores.dataType == .float32 else {
            throw OutputError.unsupportedDataType(rawValue: scores.dataType.rawValue)
        }
        let pointer = scores.dataPointer.bindMemory(to: Float.self, capacity: (batchSize - 1) * rowStride + 1)
        let values = (0..<batchSize).map { pointer[$0 * rowStride] }
        guard values.allSatisfy(\.isFinite) else { throw OutputError.nonFiniteValue }
        return values
    }
}
#endif
