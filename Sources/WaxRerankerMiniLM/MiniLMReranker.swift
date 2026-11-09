import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
import WaxBertTokenizer
import WaxCore
import WaxVectorSearch

/// On-device `cross-encoder/ms-marco-MiniLM-L-6-v2` reranker.
///
/// Each document is cut into overlapping 288-token `[CLS] query [SEP] window [SEP]` rows
/// (``CrossEncoderWindowing``) and scored as the maximum logit over its windows. The model uses
/// the bert-base-uncased WordPiece vocabulary that `BertTokenizer` already ships.
@available(macOS 15.0, iOS 18.0, *)
package final class MiniLMReranker: RerankingProvider, @unchecked Sendable {
    /// The window shape the offline evaluation measured: 288 tokens per row, consecutive windows
    /// sharing 64 document tokens.
    package static let defaultWindowing = CrossEncoderWindowing(
        maxLength: 288,
        stride: 64,
        maxQueryTokens: 128,
        maxWindowsPerDocument: 16
    )

    package let model: MiniLMRerankerModel
    package let tokenizer: BertTokenizer
    package let windowing: CrossEncoderWindowing
    /// Rows per CoreML prediction.
    package let batchSize: Int
    /// Fastest measured on CPU: windows are sorted by length, so small batches pad less.
    package static let defaultBatchSize = 8

    package init(
        model: MiniLMRerankerModel,
        tokenizer: BertTokenizer,
        windowing: CrossEncoderWindowing = defaultWindowing,
        batchSize: Int = defaultBatchSize
    ) throws {
        self.model = model
        self.tokenizer = tokenizer
        self.windowing = windowing
        self.batchSize = min(max(1, batchSize), MiniLMRerankerModel.maximumPredictionBatchSize)
    }

    /// Loads the bundled model (cached per compute unit) under `timeout`.
    package static func make(
        computeUnits: MLComputeUnits = .cpuOnly,
        batchSize: Int = defaultBatchSize,
        timeout: Duration
    ) async throws -> MiniLMReranker {
        try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM reranker model load") {
            try MiniLMReranker(
                model: MiniLMRerankerModel.bundled(computeUnits: computeUnits),
                tokenizer: BertTokenizer(),
                batchSize: batchSize
            )
        }
    }

    package func scores(query: String, documents: [String]) async throws -> [Float] {
        guard !documents.isEmpty else { return [] }
        let rows = try windows(query: query, documents: documents)
        var best = [Float](repeating: -.infinity, count: documents.count)
        for (batch, scores) in try await score(rows: rows) {
            for (window, score) in zip(batch, scores) {
                best[window.documentIndex] = max(best[window.documentIndex], score)
            }
        }
        return best
    }

    /// Every row for `documents`.
    package func windows(query: String, documents: [String]) throws -> [CrossEncoderWindow] {
        try Self.windows(query: query, documents: documents, tokenizer: tokenizer, windowing: windowing)
    }

    /// Rows for `documents`, tokenized as Hugging Face's BERT tokenizer does. An empty or blank
    /// document is scored as `"."`, as the offline evaluation did.
    package static func windows(
        query: String,
        documents: [String],
        tokenizer: BertTokenizer,
        windowing: CrossEncoderWindowing
    ) throws -> [CrossEncoderWindow] {
        let queryTokens = try tokenizer.tokenizeToIds(text: cleanedForBert(query))
        let documentTokens = try documents.map { text in
            let cleaned = cleanedForBert(text)
            let blank = cleaned.allSatisfy(\.isWhitespace)
            return try tokenizer.tokenizeToIds(text: blank ? "." : cleaned)
        }
        return windowing.windows(
            queryTokens: queryTokens,
            documentTokens: documentTokens,
            clsToken: try tokenizer.tokenToIdOrThrow(token: "[CLS]"),
            sepToken: try tokenizer.tokenToIdOrThrow(token: "[SEP]")
        )
    }

    /// Hugging Face BERT's `clean_text` step, which `BertTokenizer` does not do: drops NUL,
    /// U+FFFD and "other" scalars (control, format such as U+200B, surrogate, private use,
    /// unassigned) except tab, newline and carriage return. Without it a zero-width space
    /// becomes an extra `[UNK]` token.
    package static func cleanedForBert(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isRemovedByCleanText(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isRemovedByCleanText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0, 0xFFFD:
            return true
        case 0x09, 0x0A, 0x0D:
            return false
        default:
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                return true
            default:
                return false
            }
        }
    }

    /// Scores rows in batches of similar length (shortest first), each padded to a bucket.
    private func score(rows: [CrossEncoderWindow]) async throws -> [([CrossEncoderWindow], [Float])] {
        let sorted = rows.sorted { $0.inputIds.count < $1.inputIds.count }
        var results: [([CrossEncoderWindow], [Float])] = []
        var start = 0
        while start < sorted.count {
            let batch = Array(sorted[start..<min(sorted.count, start + batchSize)])
            let longest = batch.map(\.inputIds.count).max() ?? 0
            let scores = try await model.scores(rows: batch, sequenceLength: MiniLMRerankerModel.bucket(for: longest))
            results.append((batch, scores))
            start += batch.count
        }
        return results
    }
}
#endif
