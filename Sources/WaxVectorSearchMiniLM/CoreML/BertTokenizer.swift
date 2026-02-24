//
//  BertTokenizer.swift
//
//
//  Created by Zach Nagengast on 4/20/23.
//

import Foundation
import WaxCore
#if canImport(CoreML)
import CoreML

public struct BatchInputs {
    public let inputIds: MLMultiArray
    public let attentionMask: MLMultiArray
    public let sequenceLength: Int
    public let lengths: [Int]
}

public struct BatchInputBuffers: @unchecked Sendable {
    public var inputIds: MLMultiArray
    public var attentionMask: MLMultiArray
    public let batchSize: Int
    public let sequenceLength: Int

    public init(batchSize: Int, sequenceLength: Int) throws {
        self.batchSize = batchSize
        self.sequenceLength = sequenceLength
        self.inputIds = try MLMultiArray(
            shape: [NSNumber(value: batchSize), NSNumber(value: sequenceLength)],
            dataType: .int32
        )
        self.attentionMask = try MLMultiArray(
            shape: [NSNumber(value: batchSize), NSNumber(value: sequenceLength)],
            dataType: .int32
        )
    }
}

public final class BertTokenizer: @unchecked Sendable {
    private static let sharedBasicTokenizer = BasicTokenizer()

    /// Thread-safe container for vocab cache state, replacing `nonisolated(unsafe)` statics.
    /// All access to mutable state goes through the internal lock.
    private final class VocabCacheState: @unchecked Sendable {
        let lock = NSLock()
        var data: VocabData?
        var loadCount: Int = 0
    }

    private static let vocabCache = VocabCacheState()

    private let basicTokenizer: BasicTokenizer
    private let wordpieceTokenizer: WordpieceTokenizer
    private let maxLen = 512

    private let vocab: [String: Int]
    private let ids_to_tokens: [Int: String]

    public init() throws {
        let sharedVocab = try BertTokenizer.loadVocab()
        self.vocab = sharedVocab.vocab
        self.ids_to_tokens = sharedVocab.idsToTokens
        self.basicTokenizer = Self.sharedBasicTokenizer
        self.wordpieceTokenizer = WordpieceTokenizer(vocab: sharedVocab.vocab)
    }

    public func buildModelTokens(sentence: String) throws -> [Int] {
        var tokens = try tokenizeToIds(text: sentence)

        let clsSepTokenCount = 2 // Account for [CLS] and [SEP] tokens

        if tokens.count + clsSepTokenCount > maxLen {
            tokens = Array(tokens[..<(maxLen - clsSepTokenCount)])
        }

        let paddingCount = maxLen - tokens.count - clsSepTokenCount

        let clsToken = try tokenToIdOrThrow(token: "[CLS]")
        let sepToken = try tokenToIdOrThrow(token: "[SEP]")
        
        let inputTokens: [Int] = [
            clsToken,
        ] + tokens + [
            sepToken,
        ] + Array(repeating: 0, count: paddingCount)

        return inputTokens
    }

    /// - Note: This is lossy due to potential unknown tokens in source text
    public func detokenize(tokens: [String]) -> String {
        let decodedString = convertWordpieceToBasicTokenList(tokens)
        return decodedString
    }

    public func buildModelInputs(from inputTokens: [Int]) throws -> (MLMultiArray, MLMultiArray) {
        let inputIds = try MLMultiArray.from(inputTokens, dims: 2)
        let maskValue = 1

        let attentionMaskValues: [Int] = inputTokens.map { token in
            token == 0 ? 0 : maskValue
        }

        let attentionMask = try MLMultiArray.from(attentionMaskValues, dims: 2)

        return (inputIds, attentionMask)
    }

    public func buildBatchInputs(
        sentences: [String],
        maxSequenceLength: Int? = nil,
        sequenceLengthBuckets: [Int]? = nil
    ) throws -> BatchInputs {
        guard !sentences.isEmpty else {
            let emptyIds = try MLMultiArray(shape: [0, 0], dataType: .int32)
            let emptyMask = try MLMultiArray(shape: [0, 0], dataType: .int32)
            return BatchInputs(inputIds: emptyIds, attentionMask: emptyMask, sequenceLength: 0, lengths: [])
        }

        let maxAllowed = max(2, min(maxSequenceLength ?? maxLen, maxLen))
        let clsToken = try tokenToIdOrThrow(token: "[CLS]")
        let sepToken = try tokenToIdOrThrow(token: "[SEP]")

        var tokenSequences: [[Int]] = []
        tokenSequences.reserveCapacity(sentences.count)
        var lengths: [Int] = []
        lengths.reserveCapacity(sentences.count)
        var batchMax = 0

        for sentence in sentences {
            var tokens = try tokenizeToIds(text: sentence)
            let maxTokens = maxAllowed - 2
            if tokens.count > maxTokens {
                tokens = Array(tokens.prefix(maxTokens))
            }

            let length = tokens.count + 2
            lengths.append(length)
            batchMax = max(batchMax, length)
            tokenSequences.append(tokens)
        }

        let sequenceLength = Self.selectSequenceLength(
            requiredLength: batchMax,
            maxAllowed: maxAllowed,
            buckets: sequenceLengthBuckets
        )
        let batchSize = sentences.count
        let inputIds = try MLMultiArray(
            shape: [NSNumber(value: batchSize), NSNumber(value: sequenceLength)],
            dataType: .int32
        )
        let attentionMask = try MLMultiArray(
            shape: [NSNumber(value: batchSize), NSNumber(value: sequenceLength)],
            dataType: .int32
        )

        let idsPtr = UnsafeMutablePointer<Int32>(OpaquePointer(inputIds.dataPointer))
        let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(attentionMask.dataPointer))
        idsPtr.initialize(repeating: 0, count: inputIds.count)
        maskPtr.initialize(repeating: 0, count: attentionMask.count)

        var adjustedLengths = lengths
        for row in 0..<batchSize {
            let tokens = tokenSequences[row]
            let maxTokenCount = max(0, min(tokens.count, sequenceLength - 2))
            let base = row * sequenceLength

            idsPtr[base] = Int32(clsToken)
            maskPtr[base] = 1

            if maxTokenCount > 0 {
                for index in 0..<maxTokenCount {
                    idsPtr[base + 1 + index] = Int32(tokens[index])
                    maskPtr[base + 1 + index] = 1
                }
            }

            let sepIndex = min(sequenceLength - 1, 1 + maxTokenCount)
            idsPtr[base + sepIndex] = Int32(sepToken)
            maskPtr[base + sepIndex] = 1

            adjustedLengths[row] = min(sequenceLength, maxTokenCount + 2)
        }

        return BatchInputs(
            inputIds: inputIds,
            attentionMask: attentionMask,
            sequenceLength: sequenceLength,
            lengths: adjustedLengths
        )
    }

    public func buildBatchInputsWithReuse(
        sentences: [String],
        maxSequenceLength: Int? = nil,
        sequenceLengthBuckets: [Int]? = nil,
        reuse: inout BatchInputBuffers?
    ) throws -> BatchInputs {
        guard !sentences.isEmpty else {
            let emptyIds = try MLMultiArray(shape: [0, 0], dataType: .int32)
            let emptyMask = try MLMultiArray(shape: [0, 0], dataType: .int32)
            return BatchInputs(inputIds: emptyIds, attentionMask: emptyMask, sequenceLength: 0, lengths: [])
        }

        let maxAllowed = max(2, min(maxSequenceLength ?? maxLen, maxLen))
        let clsToken = try tokenToIdOrThrow(token: "[CLS]")
        let sepToken = try tokenToIdOrThrow(token: "[SEP]")

        var tokenSequences: [[Int]] = []
        tokenSequences.reserveCapacity(sentences.count)
        var lengths: [Int] = []
        lengths.reserveCapacity(sentences.count)
        var batchMax = 0

        for sentence in sentences {
            var tokens = try tokenizeToIds(text: sentence)
            let maxTokens = maxAllowed - 2
            if tokens.count > maxTokens {
                tokens = Array(tokens.prefix(maxTokens))
            }

            let length = tokens.count + 2
            lengths.append(length)
            batchMax = max(batchMax, length)
            tokenSequences.append(tokens)
        }

        let sequenceLength = Self.selectSequenceLength(
            requiredLength: batchMax,
            maxAllowed: maxAllowed,
            buckets: sequenceLengthBuckets
        )
        let batchSize = sentences.count

        if reuse == nil || reuse?.batchSize != batchSize || reuse?.sequenceLength != sequenceLength {
            reuse = try BatchInputBuffers(batchSize: batchSize, sequenceLength: sequenceLength)
        }

        guard let buffers = reuse else {
            throw WaxError.io("Failed to allocate batch input buffers")
        }

        let idsPtr = UnsafeMutablePointer<Int32>(OpaquePointer(buffers.inputIds.dataPointer))
        let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(buffers.attentionMask.dataPointer))
        idsPtr.initialize(repeating: 0, count: buffers.inputIds.count)
        maskPtr.initialize(repeating: 0, count: buffers.attentionMask.count)

        var adjustedLengths = lengths
        for row in 0..<batchSize {
            let tokens = tokenSequences[row]
            let maxTokenCount = max(0, min(tokens.count, sequenceLength - 2))
            let base = row * sequenceLength

            idsPtr[base] = Int32(clsToken)
            maskPtr[base] = 1

            if maxTokenCount > 0 {
                for index in 0..<maxTokenCount {
                    idsPtr[base + 1 + index] = Int32(tokens[index])
                    maskPtr[base + 1 + index] = 1
                }
            }

            let sepIndex = min(sequenceLength - 1, 1 + maxTokenCount)
            idsPtr[base + sepIndex] = Int32(sepToken)
            maskPtr[base + sepIndex] = 1

            adjustedLengths[row] = min(sequenceLength, maxTokenCount + 2)
        }

        reuse = buffers
        return BatchInputs(
            inputIds: buffers.inputIds,
            attentionMask: buffers.attentionMask,
            sequenceLength: sequenceLength,
            lengths: adjustedLengths
        )
    }
    
    /**
     Builds model inputs with type IDs from the given input tokens.

     - Parameters:
       - inputTokens: An array of integers representing input tokens.

     - Returns: A tuple containing three `MLMultiArray` objects:
       - The first `MLMultiArray` represents input IDs.
       - The second `MLMultiArray` is the attention mask.
       - The third `MLMultiArray` contains token type IDs.
    */
    public func buildModelInputsWithTypeIds(from inputTokens: [Int]) throws -> (MLMultiArray, MLMultiArray, MLMultiArray) {
        let (inputIds, attentionMask) = try buildModelInputs(from: inputTokens)
        
        var encounteredSep = false
        guard let sepToken = tokenToId(token: "[SEP]") else {
            throw WaxError.io("Missing required [SEP] token in vocabulary")
        }
        let tokenTypeIdValues: [Int] = inputTokens.map { token in
            if token == sepToken {
                encounteredSep = true
            }
            return encounteredSep ? 1 : 0
        }
        let tokenTypeIds = try MLMultiArray.from(tokenTypeIdValues, dims: 2)
        return (inputIds, attentionMask, tokenTypeIds)
    }

    public func tokenize(text: String) -> [String] {
        var tokens: [String] = []
        for token in basicTokenizer.tokenize(text: text) {
            for subToken in wordpieceTokenizer.tokenize(word: token) {
                tokens.append(subToken)
            }
        }
        return tokens
    }

    public func convertTokensToIds(tokens: [String]) throws -> [Int] {
        return try tokens.map { token in
            guard let id = vocab[token] else {
                throw WaxError.io("Unknown token in vocabulary: \(token)")
            }
            return id
        }
    }

    /// Main entry point
    func tokenizeToIds(text: String) throws -> [Int] {
        return try convertTokensToIds(tokens: tokenize(text: text))
    }

    func tokenToId(token: String) -> Int? {
        return vocab[token]
    }

    func tokenToIdOrThrow(token: String) throws -> Int {
        guard let id = vocab[token] else {
            throw WaxError.io("Unknown token in vocabulary: \(token)")
        }
        return id
    }

    /// Un-tokenization: get tokens from tokenIds
    func idsToTokens(tokenIds: [Int]) throws -> [String] {
        return try tokenIds.map { id in
            guard let token = ids_to_tokens[id] else {
                throw WaxError.io("Unknown token ID in vocabulary: \(id)")
            }
            return token
        }
    }

    func convertWordpieceToBasicTokenList(_ wordpieceTokenList: [String]) -> String {
        var tokenList: [String] = []
        var individualToken: String = ""

        for token in wordpieceTokenList {
            if token.starts(with: "##") {
                individualToken += String(token.suffix(token.count - 2))
            } else {
                if individualToken.count > 0 {
                    tokenList.append(individualToken)
                }

                individualToken = token
            }
        }

        tokenList.append(individualToken)

        return tokenList.joined(separator: " ")
    }
}

private extension BertTokenizer {
    struct VocabData {
        let vocab: [String: Int]
        let idsToTokens: [Int: String]
    }

    static func loadVocab() throws -> VocabData {
        vocabCache.lock.lock()
        if let cached = vocabCache.data {
            vocabCache.lock.unlock()
            return cached
        }
        vocabCache.lock.unlock()

        guard let url = Bundle.module.url(forResource: "bert_tokenizer_vocab", withExtension: "txt") else {
            throw WaxError.io("Missing vocabulary file: bert_tokenizer_vocab.txt")
        }
        let vocabTxt = try String(contentsOf: url, encoding: .utf8)
        let tokens = vocabTxt.split(separator: "\n").map { String($0) }
        var vocab: [String: Int] = [:]
        var idsToTokens: [Int: String] = [:]
        vocab.reserveCapacity(tokens.count)
        idsToTokens.reserveCapacity(tokens.count)
        for (i, token) in tokens.enumerated() {
            vocab[token] = i
            idsToTokens[i] = token
        }
        let loaded = VocabData(vocab: vocab, idsToTokens: idsToTokens)
        vocabCache.lock.lock()
        if let cached = vocabCache.data {
            vocabCache.lock.unlock()
            return cached
        }
        vocabCache.data = loaded
        vocabCache.loadCount += 1
        vocabCache.lock.unlock()
        return loaded
    }

    static func selectSequenceLength(
        requiredLength: Int,
        maxAllowed: Int,
        buckets: [Int]?
    ) -> Int {
        guard let buckets, !buckets.isEmpty else {
            return min(requiredLength, maxAllowed)
        }
        let sorted = buckets.sorted()
        if let match = sorted.first(where: { $0 >= requiredLength && $0 <= maxAllowed }) {
            return match
        }
        return min(requiredLength, maxAllowed)
    }
}

#if DEBUG
extension BertTokenizer {
    static func _resetVocabCacheForTests() {
        vocabCache.lock.lock()
        vocabCache.data = nil
        vocabCache.loadCount = 0
        vocabCache.lock.unlock()
    }

    static func _vocabLoadCountForTests() -> Int {
        vocabCache.lock.lock()
        let count = vocabCache.loadCount
        vocabCache.lock.unlock()
        return count
    }
}
#endif

#endif // canImport(CoreML)

final class BasicTokenizer: @unchecked Sendable {
    let neverSplit = [
        "[UNK]", "[SEP]", "[PAD]", "[CLS]", "[MASK]",
    ]

    func tokenize(text: String) -> [String] {
        let foldedText = text.folding(options: .diacriticInsensitive, locale: nil)
        let splitTokens = foldedText.components(separatedBy: NSCharacterSet.whitespaces)

        let tokens: [String] = splitTokens.flatMap { token -> [String] in
            if neverSplit.contains(token) {
                return [token]
            }

            var tokenFragments: [String] = []
            var currentFragment = ""

            for character in token.lowercased() {
                if character.isLetter || character.isNumber || character == "°" {
                    currentFragment.append(character)
                } else if !currentFragment.isEmpty {
                    tokenFragments.append(currentFragment)
                    tokenFragments.append(String(character))
                    currentFragment = ""
                } else {
                    tokenFragments.append(String(character))
                }
            }

            if !currentFragment.isEmpty {
                tokenFragments.append(currentFragment)
            }

            return tokenFragments
        }

        return tokens
    }
}

final class WordpieceTokenizer: @unchecked Sendable {
    private let unkToken = "[UNK]"
    private let maxInputCharsPerWord = 100
    private let vocab: [String: Int]

    init(vocab: [String: Int]) {
        self.vocab = vocab
    }

    /// `word`: A single token.
    /// Warning: this differs from the `pytorch-transformers` implementation.
    /// This should have already been passed through `BasicTokenizer`.
    func tokenize(word: String) -> [String] {
        if word.count > maxInputCharsPerWord {
            return [unkToken]
        }

        var outputTokens: [String] = []
        var isBad = false
        var start = 0
        var subTokens: [String] = []

        while start < word.count {
            var end = word.count
            var currentSubstring: String?

            while start < end {
                guard var substring = Utils.substr(word, start..<end) else {
                    end -= 1
                    continue
                }
                if start > 0 {
                    substring = "##\(substring)"
                }

                if vocab[substring] != nil {
                    currentSubstring = substring
                    break
                }

                end -= 1
            }

            guard let substring = currentSubstring else {
                isBad = true
                break
            }

            subTokens.append(substring)
            start = end
        }

        if isBad {
            outputTokens.append(unkToken)
        } else {
            outputTokens.append(contentsOf: subTokens)
        }

        return outputTokens
    }
}

struct Utils {
    /// Time a block in ms
    static func time<T>(label: String, _ block: () -> T) -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = block()
        let diff = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[\(label)] \(diff)ms")
        return result
    }

    /// Time a block in seconds and return (output, time)
    static func time<T>(_ block: () -> T) -> (T, Double) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = block()
        let diff = CFAbsoluteTimeGetCurrent() - startTime
        return (result, diff)
    }

    /// Return unix timestamp in ms
    static func dateNow() -> Int64 {
        // Use `Int` when we don't support 32-bits devices/OSes anymore.
        // Int crashes on iPhone 5c.
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Clamp a val to [min, max]
    static func clamp<T: Comparable>(_ val: T, _ vmin: T, _ vmax: T) -> T {
        return min(max(vmin, val), vmax)
    }

    /// Fake func that can throw.
    static func fakeThrowable<T>(_ input: T) throws -> T {
        return input
    }

    /// Substring
    static func substr(_ s: String, _ r: Range<Int>) -> String? {
        let stringCount = s.count
        if stringCount < r.upperBound || stringCount < r.lowerBound {
            return nil
        }
        let startIndex = s.index(s.startIndex, offsetBy: r.lowerBound)
        let endIndex = s.index(s.startIndex, offsetBy: r.upperBound)
        return String(s[startIndex..<endIndex])
    }

    /// Invert a (k, v) dictionary
    static func invert<K, V>(_ dict: [K: V]) -> [V: K] {
        var inverted: [V: K] = [:]
        for (k, v) in dict {
            inverted[v] = k
        }
        return inverted
    }
}

#if canImport(CoreML)
extension MLMultiArray {
    /// All values will be stored in the last dimension of the MLMultiArray (default is dims=1)
    static func from(_ arr: [Int], dims: Int = 1) throws -> MLMultiArray {
        var shape = Array(repeating: 1, count: dims)
        shape[shape.count - 1] = arr.count
        /// Examples:
        /// dims=1 : [arr.count]
        /// dims=2 : [1, arr.count]
        ///
        let o = try MLMultiArray(shape: shape as [NSNumber], dataType: .int32)
        let ptr = UnsafeMutablePointer<Int32>(OpaquePointer(o.dataPointer))
        for (i, item) in arr.enumerated() {
            ptr[i] = Int32(item)
        }
        return o
    }

    /// This will concatenate all dimensions into one one-dim array.
    static func toIntArray(_ o: MLMultiArray) -> [Int] {
        var arr = Array(repeating: 0, count: o.count)
        let ptr = UnsafeMutablePointer<Int32>(OpaquePointer(o.dataPointer))
        for i in 0..<o.count {
            arr[i] = Int(ptr[i])
        }
        return arr
    }

    /// This will concatenate all dimensions into one one-dim array.
    static func toDoubleArray(_ o: MLMultiArray) -> [Double] {
        var arr: [Double] = Array(repeating: 0, count: o.count)
        let ptr = UnsafeMutablePointer<Double>(OpaquePointer(o.dataPointer))
        for i in 0..<o.count {
            arr[i] = Double(ptr[i])
        }
        return arr
    }

    static func toFloatArray(_ o: MLMultiArray) -> [Float] {
        var arr: [Float] = Array(repeating: 0, count: o.count)
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(o.dataPointer))
        for i in 0..<o.count {
            arr[i] = Float(ptr[i])
        }
        return arr
    }

    /// Helper to construct a sequentially-indexed multi array,
    /// useful for debugging and unit tests
    /// Example in 3 dimensions:
    /// ```
    /// [[[ 0, 1, 2, 3 ],
    ///   [ 4, 5, 6, 7 ],
    ///   [ 8, 9, 10, 11 ]],
    ///  [[ 12, 13, 14, 15 ],
    ///   [ 16, 17, 18, 19 ],
    ///   [ 20, 21, 22, 23 ]]]
    /// ```
    static func testTensor(shape: [Int]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape as [NSNumber], dataType: .double)
        let ptr = UnsafeMutablePointer<Double>(OpaquePointer(arr.dataPointer))
        for i in 0..<arr.count {
            ptr.advanced(by: i).pointee = Double(i)
        }
        return arr
    }

    static func from(batch: [[Int]], sequenceLength: Int? = nil) throws -> MLMultiArray {
        let batchSize = batch.count
        guard batchSize > 0 else {
            return try MLMultiArray(shape: [0, 0], dataType: .int32)
        }

        let maxCount = batch.map { $0.count }.max() ?? 0
        let seqLength = max(0, sequenceLength ?? maxCount)
        let array = try MLMultiArray(
            shape: [NSNumber(value: batchSize), NSNumber(value: seqLength)],
            dataType: .int32
        )

        let ptr = UnsafeMutablePointer<Int32>(OpaquePointer(array.dataPointer))
        ptr.initialize(repeating: 0, count: array.count)

        for row in 0..<batchSize {
            let tokens = batch[row]
            let count = min(tokens.count, seqLength)
            let base = row * seqLength
            for idx in 0..<count {
                ptr[base + idx] = Int32(tokens[idx])
            }
        }
        return array
    }
}
#endif // canImport(CoreML)
