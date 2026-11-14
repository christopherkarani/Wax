#if canImport(WaxBertTokenizer)
import Testing
import WaxBertTokenizer

/// `buildTokenIDBatch` is the Core ML-free tokenizer path the WaxMILRuntime embedders use. It must
/// lay rows out exactly as `buildBatchInputs` does for Core ML.
struct BertTokenizerTokenIDBatchTests {
    static let cls: Int32 = 101
    static let sep: Int32 = 102

    @Test func rowsAreClsTokensSepThenZeroPaddingToTheLongestRow() throws {
        let tokenizer = try BertTokenizer()
        let batch = try tokenizer.buildTokenIDBatch(sentences: ["hello world", "hello"])
        let hello = Int32(try #require(tokenizer.tokenToId(token: "hello")))
        let world = Int32(try #require(tokenizer.tokenToId(token: "world")))

        #expect(batch.sequenceLength == 4)
        #expect(batch.lengths == [4, 3])
        #expect(batch.inputIDs == [[Self.cls, hello, world, Self.sep], [Self.cls, hello, Self.sep, 0]])
        #expect(batch.attentionMask == [[1, 1, 1, 1], [1, 1, 1, 0]])
    }

    /// Ids from the Hugging Face BERT tokenizer over the bundled vocabulary (the same ids as the
    /// WaxMILRuntime reference fixture), including the e5 and Arctic prefixes.
    @Test(arguments: [
        ("Swift concurrency makes structured parallelism practical.",
         [101, 9170, 24154, 3084, 14336, 5903, 2964, 6742, 1012, 102] as [Int32]),
        ("passage: Hello world", [101, 6019, 1024, 7592, 2088, 102]),
        ("query: What degree did I graduate with?", [101, 23032, 1024, 2054, 3014, 2106, 1045, 4619, 2007, 1029, 102]),
        ("Represent this sentence for searching relevant passages: What are the benefits of exercise?",
         [101, 5050, 2023, 6251, 2005, 6575, 7882, 13768, 1024, 2054, 2024, 1996, 6666, 1997, 6912, 1029, 102]),
    ])
    func matchesHuggingFaceIDs(text: String, expected: [Int32]) throws {
        let batch = try BertTokenizer().buildTokenIDBatch(sentences: [text])
        #expect(batch.inputIDs == [expected])
        #expect(batch.attentionMask == [[Int32](repeating: 1, count: expected.count)])
    }

    @Test func truncatesToMaxSequenceLengthKeepingTheFinalSep() throws {
        let tokenizer = try BertTokenizer()
        let long = Array(repeating: "token", count: 64).joined(separator: " ")
        let batch = try tokenizer.buildTokenIDBatch(sentences: [long, "token"], maxSequenceLength: 8)
        let token = Int32(try #require(tokenizer.tokenToId(token: "token")))

        #expect(batch.sequenceLength == 8)
        #expect(batch.lengths == [8, 3])
        #expect(batch.inputIDs[0] == [Self.cls] + [Int32](repeating: token, count: 6) + [Self.sep])
        #expect(batch.inputIDs[1] == [Self.cls, token, Self.sep, 0, 0, 0, 0, 0])
        #expect(batch.attentionMask[1] == [1, 1, 1, 0, 0, 0, 0, 0])
    }

    @Test func maxSequenceLengthIsCappedAt512() throws {
        let long = Array(repeating: "token", count: 700).joined(separator: " ")
        let batch = try BertTokenizer().buildTokenIDBatch(sentences: [long], maxSequenceLength: 4_096)
        #expect(batch.sequenceLength == 512)
        #expect(batch.inputIDs[0].last == Self.sep)
    }

    @Test func padsToTheSmallestBucketThatFits() throws {
        let tokenizer = try BertTokenizer()
        let short = try tokenizer.buildTokenIDBatch(sentences: ["hello"], sequenceLengthBuckets: [64, 32])
        #expect(short.sequenceLength == 32)
        #expect(short.lengths == [3])
        #expect(short.attentionMask[0].reduce(0, +) == 3)

        // No bucket fits under the cap: the row keeps its own length.
        let capped = try tokenizer.buildTokenIDBatch(
            sentences: ["hello world again"],
            maxSequenceLength: 4,
            sequenceLengthBuckets: [32]
        )
        #expect(capped.sequenceLength == 4)
    }

    @Test func emptyBatchHasNoRows() throws {
        let batch = try BertTokenizer().buildTokenIDBatch(sentences: [])
        #expect(batch.inputIDs.isEmpty)
        #expect(batch.attentionMask.isEmpty)
        #expect(batch.sequenceLength == 0)
    }

    @Test func emptyTextIsClsSep() throws {
        let batch = try BertTokenizer().buildTokenIDBatch(sentences: [""])
        #expect(batch.inputIDs == [[Self.cls, Self.sep]])
        #expect(batch.lengths == [2])
    }
}

#if canImport(CoreML)
import CoreML

/// On Apple platforms both builders must produce identical rows.
@Test(arguments: [nil, [32, 64, 128, 256]] as [[Int]?])
func tokenIDBatchMatchesTheCoreMLBatchInputs(buckets: [Int]?) throws {
    let tokenizer = try BertTokenizer()
    let sentences = [
        "hello world",
        Array(repeating: "token", count: 300).joined(separator: " "),
        "On-device inference keeps user data private.",
    ]
    let plain = try tokenizer.buildTokenIDBatch(sentences: sentences, maxSequenceLength: 256, sequenceLengthBuckets: buckets)
    let coreML = try tokenizer.buildBatchInputs(sentences: sentences, maxSequenceLength: 256, sequenceLengthBuckets: buckets)
    #expect(plain.sequenceLength == coreML.sequenceLength)
    #expect(plain.lengths == coreML.lengths)
    #expect(plain.inputIDs.flatMap { $0 }.map(Int.init) == MLMultiArray.toIntArray(coreML.inputIds))
    #expect(plain.attentionMask.flatMap { $0 }.map(Int.init) == MLMultiArray.toIntArray(coreML.attentionMask))
}
#endif
#endif
