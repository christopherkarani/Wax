import Foundation
import WaxCore
import WaxMILEncoder
import WaxMILRuntime

/// The bundled `cross-encoder/ms-marco-MiniLM-L-6-v2` graph run by WaxMILRuntime, without Core ML:
/// token ids, attention mask and segment ids in, one relevance logit per row out (`scores`,
/// `[batch, 1]`).
///
/// On platforms without Core ML this is `MiniLMRerankerModel`. It is built everywhere so Apple
/// test runs can compare the two runtimes.
package final class MiniLMRerankerMILModel: Sendable {
    package enum LoadError: LocalizedError, Sendable, Equatable {
        case missingModelResource
        case modelLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                "Could not find the ms-marco-MiniLM-L-6-v2 model in the WaxRerankerMiniLM bundle."
            case .modelLoadFailed(let details):
                "Failed to load the ms-marco-MiniLM-L-6-v2 model in WaxMILRuntime: \(details)"
            }
        }
    }

    /// The Core ML model's buckets (`MiniLMRerankerModel`), so batches are formed the same way.
    package static let sequenceLengthBuckets = [32, 64, 128, 192, 256, 288, 384, 512]
    package static let maximumPredictionBatchSize = 64

    package let model: MILModel

    package init(model: MILModel) {
        self.model = model
    }

    /// The bundled model, loaded once for the process.
    package static func bundled() throws -> MiniLMRerankerMILModel {
        guard let directory = MILBundledModels.modelDirectory(
            named: "ms-marco-MiniLM-L-6-v2",
            bundleBaseName: "Wax_WaxRerankerMiniLM",
            module: .module
        ) else {
            throw LoadError.missingModelResource
        }
        do {
            return MiniLMRerankerMILModel(model: try MILBundledModels.model(at: directory))
        } catch {
            throw LoadError.modelLoadFailed(String(describing: error))
        }
    }

    /// The smallest bucket that holds `length` tokens.
    package static func bucket(for length: Int) -> Int {
        sequenceLengthBuckets.first { $0 >= length } ?? sequenceLengthBuckets[sequenceLengthBuckets.count - 1]
    }

    /// Scores `rows` in one prediction on a GCD thread. Rows are cut to `sequenceLength` tokens
    /// and padded (masked) to the longest; the interpreter needs no fixed bucket shape.
    package func scores(rows: [CrossEncoderWindow], sequenceLength: Int) async throws -> [Float] {
        guard !rows.isEmpty else { return [] }
        return try await BlockingWork.run { [self] () throws -> [Float] in
            try scoresBlocking(rows: rows, sequenceLength: sequenceLength)
        }
    }

    /// `scores(rows:sequenceLength:)` on the calling thread, which it blocks.
    package func scoresBlocking(rows: [CrossEncoderWindow], sequenceLength: Int) throws -> [Float] {
        guard !rows.isEmpty else { return [] }
        let width = min(sequenceLength, rows.map(\.inputIds.count).max() ?? 0)
        var ids: [[Int32]] = []
        var mask: [[Int32]] = []
        var types: [[Int32]] = []
        for window in rows {
            let length = min(window.inputIds.count, width)
            let padding = [Int32](repeating: 0, count: width - length)
            ids.append(Array(window.inputIds.prefix(length)) + padding)
            mask.append([Int32](repeating: 1, count: length) + padding)
            types.append(Array(window.tokenTypeIds.prefix(length)) + padding)
        }
        let outputs = try model.predict(inputIDs: ids, attentionMask: mask, tokenTypeIDs: types)
        guard let scores = outputs["scores"] else {
            throw MILEncoderOutputError.missingOutput(name: "scores")
        }
        return try MILBundledModels.rows(scores, rows: rows.count, columns: 1).map { $0[0] }
    }
}

#if !canImport(CoreML)
/// Without Core ML, the reranker model runs on WaxMILRuntime.
package typealias MiniLMRerankerModel = MiniLMRerankerMILModel
#endif
