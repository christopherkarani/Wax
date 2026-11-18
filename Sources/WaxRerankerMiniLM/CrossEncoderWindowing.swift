import Foundation

/// One `[CLS] query [SEP] window [SEP]` input row for a BERT cross-encoder.
package struct CrossEncoderWindow: Sendable, Equatable {
    /// Index of the document this window was cut from.
    package let documentIndex: Int
    package let inputIds: [Int32]
    /// BERT segment ids: 0 through the first `[SEP]`, 1 for the window and the final `[SEP]`.
    package let tokenTypeIds: [Int32]

    package init(documentIndex: Int, inputIds: [Int32], tokenTypeIds: [Int32]) {
        self.documentIndex = documentIndex
        self.inputIds = inputIds
        self.tokenTypeIds = tokenTypeIds
    }
}

/// Splits documents into overlapping windows the way Hugging Face tokenizers do for
/// `truncation="only_second", max_length=maxLength, stride=stride, return_overflowing_tokens=True`:
/// each window holds `maxLength - query - 3` document tokens and starts `stride` tokens before
/// the previous window ended.
package struct CrossEncoderWindowing: Sendable, Equatable {
    /// Tokens per row, special tokens included.
    package let maxLength: Int
    /// Document tokens shared by consecutive windows.
    package let stride: Int
    /// Query tokens kept; a longer query is truncated so documents keep most of the row.
    package let maxQueryTokens: Int
    /// Windows scored per document; later text in a longer document is not scored.
    package let maxWindowsPerDocument: Int

    package init(maxLength: Int, stride: Int, maxQueryTokens: Int, maxWindowsPerDocument: Int) {
        precondition(maxLength >= 8, "maxLength must leave room for special tokens and a document")
        self.maxLength = maxLength
        self.stride = max(0, stride)
        self.maxQueryTokens = min(max(1, maxQueryTokens), maxLength / 2)
        self.maxWindowsPerDocument = max(1, maxWindowsPerDocument)
    }

    /// Rows for every document, in document order and then window order.
    package func windows(
        queryTokens: [Int],
        documentTokens: [[Int]],
        clsToken: Int,
        sepToken: Int
    ) -> [CrossEncoderWindow] {
        let query = queryTokens.prefix(maxQueryTokens).map { Int32($0) }
        let head = [Int32(clsToken)] + query + [Int32(sepToken)]
        let headTypes = [Int32](repeating: 0, count: head.count)
        let capacity = maxLength - head.count - 1
        let step = stride < capacity ? capacity - stride : capacity
        var rows: [CrossEncoderWindow] = []
        for (documentIndex, tokens) in documentTokens.enumerated() {
            var start = 0
            var emitted = 0
            while emitted < maxWindowsPerDocument {
                let end = min(tokens.count, start + capacity)
                let body = tokens[start..<end].map { Int32($0) } + [Int32(sepToken)]
                rows.append(CrossEncoderWindow(
                    documentIndex: documentIndex,
                    inputIds: head + body,
                    tokenTypeIds: headTypes + [Int32](repeating: 1, count: body.count)
                ))
                emitted += 1
                if end >= tokens.count { break }
                start += step
            }
        }
        return rows
    }
}
