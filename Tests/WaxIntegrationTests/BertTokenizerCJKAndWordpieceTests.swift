#if canImport(WaxVectorSearchMiniLM)
import Foundation
import Testing
@testable import WaxVectorSearchMiniLM

// Expected ids come from the Hugging Face `tokenizers` BERT pipeline
// (BertNormalizer(handle_chinese_chars: true, lowercase: true) + BertPreTokenizer +
// WordPiece(max_input_chars_per_word: 100)) over the bundled vocab.
@Test(
    "BertTokenizer splits CJK ideographs into single-character tokens like BERT",
    arguments: [
        ("我爱北京天安门", [1855, 100, 1781, 1755, 1811, 1820, 100]),
        ("Wax支持中文search测试", [13844, 100, 100, 1746, 1861, 3945, 100, 100]),
        ("東京タワー is tall", [1879, 1755, 1709, 30262, 30265, 2003, 4206]),
        ("日本語のテキスト", [1864, 1876, 1950, 1671, 30239, 30227, 30233, 30240]),
    ]
)
func bertTokenizerSplitsCJKCharacters(text: String, expectedIds: [Int]) throws {
    let tokenizer = try BertTokenizer()
    #expect(try tokenizer.tokenizeToIds(text: text) == expectedIds)
}

@Test("WordPiece maps words longer than 100 characters to [UNK]")
func bertTokenizerMapsOverlongWordToUnknown() throws {
    let tokenizer = try BertTokenizer()
    #expect(tokenizer.tokenize(text: String(repeating: "a", count: 101)) == ["[UNK]"])
    #expect(tokenizer.tokenize(text: String(repeating: "a", count: 100)) != ["[UNK]"])
}

@Test("WordPiece stays fast on many pathological 100-character words")
func bertTokenizerHandlesPathologicalWordsQuickly() throws {
    let tokenizer = try BertTokenizer()
    // Greedy longest-match fails at every length except one character, so a naive
    // implementation rebuilds O(n) substrings O(n) times per start offset: O(n^3) per word.
    let word = String(repeating: "qz", count: 50)
    let text = Array(repeating: word, count: 400).joined(separator: " ")

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        _ = tokenizer.tokenize(text: text)
    }
    // Generous bound: the cubic implementation takes tens of seconds here in debug builds;
    // the bounded implementation takes well under a second.
    #expect(elapsed < .seconds(5), "Tokenizing 400 pathological words took \(elapsed)")
    let expected = word.enumerated().map { index, character in
        index == 0 ? String(character) : "##\(character)"
    }
    #expect(tokenizer.tokenize(text: word) == expected)
}
#endif
