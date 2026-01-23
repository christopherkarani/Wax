//
//  BertTokenizer.swift
//
//
//  Created by Zach Nagengast on 4/20/23.
//

import Foundation
import CoreML

public class BertTokenizer {
    private let basicTokenizer = BasicTokenizer()
    private let wordpieceTokenizer: WordpieceTokenizer
    private let maxLen = 512

    private let vocab: [String: Int]
    private let ids_to_tokens: [Int: String]

    public init() {
        let url = Bundle.module.url(forResource: "bert_tokenizer_vocab", withExtension: "txt")!
        let vocabTxt = try! String(contentsOf: url, encoding: .utf8)
        let tokens = vocabTxt.split(separator: "\n").map { String($0) }
        var vocab: [String: Int] = [:]
        var ids_to_tokens: [Int: String] = [:]
        for (i, token) in tokens.enumerated() {
            vocab[token] = i
            ids_to_tokens[i] = token
        }
        self.vocab = vocab
        self.ids_to_tokens = ids_to_tokens
        self.wordpieceTokenizer = WordpieceTokenizer(vocab: self.vocab)
    }

    public func buildModelTokens(sentence: String) -> [Int] {
        var tokens = tokenizeToIds(text: sentence)

        let clsSepTokenCount = 2 // Account for [CLS] and [SEP] tokens

        if tokens.count + clsSepTokenCount > maxLen {
            print("Input sentence is too long \(tokens.count + clsSepTokenCount) > \(maxLen), truncating.")
            tokens = Array(tokens[..<(maxLen - clsSepTokenCount)])
        }

        let paddingCount = maxLen - tokens.count - clsSepTokenCount

        let inputTokens: [Int] = [
            tokenToId(token: "[CLS]"),
        ] + tokens + [
            tokenToId(token: "[SEP]"),
        ] + Array(repeating: 0, count: paddingCount)

        return inputTokens
    }

    /// - Note: This is lossy due to potential unknown tokens in source text
    public func detokenize(tokens: [String]) -> String {
        let decodedString = convertWordpieceToBasicTokenList(tokens)
        return decodedString
    }

    public func buildModelInputs(from inputTokens: [Int]) -> (MLMultiArray, MLMultiArray) {
        let inputIds = MLMultiArray.from(inputTokens, dims: 2)
        let maskValue = 1

        let attentionMaskValues: [Int] = inputTokens.map { token in
            token == 0 ? 0 : maskValue
        }

        let attentionMask = MLMultiArray.from(attentionMaskValues, dims: 2)

        return (inputIds, attentionMask)
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
    public func buildModelInputsWithTypeIds(from inputTokens: [Int]) -> (MLMultiArray, MLMultiArray, MLMultiArray) {
        let (inputIds, attentionMask) = buildModelInputs(from: inputTokens)
        
        var encounteredSep = false
        let sepToken = tokenToId(token: "[SEP]")
        let tokenTypeIdValues: [Int] = inputTokens.map { token in
            if token == sepToken {
                encounteredSep = true
            }
            return encounteredSep ? 1 : 0
        }
        let tokenTypeIds = MLMultiArray.from(tokenTypeIdValues, dims: 2)
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
        return tokens.map { vocab[$0]! }
    }

    /// Main entry point
    func tokenizeToIds(text: String) -> [Int] {
        return try! convertTokensToIds(tokens: tokenize(text: text))
    }

    func tokenToId(token: String) -> Int {
        return vocab[token]!
    }

    /// Un-tokenization: get tokens from tokenIds
    func idsToTokens(tokenIds: [Int]) -> [String] {
        return tokenIds.map { ids_to_tokens[$0]! }
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

class BasicTokenizer {
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

class WordpieceTokenizer {
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
                var substring = Utils.substr(word, start..<end)!
                if start > 0 {
                    substring = "##\(substring)"
                }

                if vocab[substring] != nil {
                    currentSubstring = substring
                    break
                }

                end -= 1
            }

            if currentSubstring == nil {
                isBad = true
                break
            }

            subTokens.append(currentSubstring!)
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

extension MLMultiArray {
    /// All values will be stored in the last dimension of the MLMultiArray (default is dims=1)
    static func from(_ arr: [Int], dims: Int = 1) -> MLMultiArray {
        var shape = Array(repeating: 1, count: dims)
        shape[shape.count - 1] = arr.count
        /// Examples:
        /// dims=1 : [arr.count]
        /// dims=2 : [1, arr.count]
        ///
        let o = try! MLMultiArray(shape: shape as [NSNumber], dataType: .int32)
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
    static func testTensor(shape: [Int]) -> MLMultiArray {
        let arr = try! MLMultiArray(shape: shape as [NSNumber], dataType: .double)
        let ptr = UnsafeMutablePointer<Double>(OpaquePointer(arr.dataPointer))
        for i in 0..<arr.count {
            ptr.advanced(by: i).pointee = Double(i)
        }
        return arr
    }
}
