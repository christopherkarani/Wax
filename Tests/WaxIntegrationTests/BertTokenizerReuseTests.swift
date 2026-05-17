#if canImport(WaxBertTokenizer) && canImport(CoreML)
import CoreML
import Testing
@testable import WaxBertTokenizer

@Test
func bertTokenizerBuildBatchInputsReusesBuffers() throws {
    let tokenizer = try BertTokenizer()
    var reuse: BatchInputBuffers?

    let first = try tokenizer.buildBatchInputsWithReuse(
        sentences: ["hello world"],
        reuse: &reuse
    )
    let firstIdsPtr = UInt(bitPattern: first.inputIds.dataPointer)
    let firstMaskPtr = UInt(bitPattern: first.attentionMask.dataPointer)

    let second = try tokenizer.buildBatchInputsWithReuse(
        sentences: ["hello world"],
        reuse: &reuse
    )
    let secondIdsPtr = UInt(bitPattern: second.inputIds.dataPointer)
    let secondMaskPtr = UInt(bitPattern: second.attentionMask.dataPointer)

    #expect(firstIdsPtr == secondIdsPtr)
    #expect(firstMaskPtr == secondMaskPtr)
}

@Test
func bertTokenizerVocabLoadsOnceAcrossInstances() throws {
    BertTokenizer._resetVocabCacheForTests()
    _ = try BertTokenizer()
    _ = try BertTokenizer()

    #expect(BertTokenizer._vocabLoadCountForTests() == 1)
}

@Test
func sharedTokenizerProducesSameTokensForBothTargets() throws {
    // Verify the shared WaxBertTokenizer produces valid tokens
    let tokenizer = try BertTokenizer()
    let tokens = tokenizer.tokenize(text: "Hello world, this is a test.")
    #expect(!tokens.isEmpty)
    #expect(tokens.contains("hello"))
    #expect(tokens.contains("world"))

    // Verify token IDs roundtrip
    let ids = try tokenizer.convertTokensToIds(tokens: tokens)
    #expect(ids.count == tokens.count)
    let recovered = try tokenizer.idsToTokens(tokenIds: ids)
    #expect(recovered == tokens)
}

@Test
func bertTokenizerTreatsNewlinesAsWhitespace() throws {
    let tokenizer = try BertTokenizer()

    let newlineSeparatedTokens = tokenizer.tokenize(text: "Hello\nworld\nthis is Wax")
    let whitespaceSeparatedTokens = tokenizer.tokenize(text: "Hello world this is Wax")

    #expect(newlineSeparatedTokens == whitespaceSeparatedTokens)
}

@Test
func bertTokenizerSingleSentenceTypeIdsKeepSepAndPaddingInSegmentZero() throws {
    let tokenizer = try BertTokenizer()
    let inputTokens = try tokenizer.buildModelTokens(sentence: "hello world")

    let (_, attentionMask, tokenTypeIds) = try tokenizer.buildModelInputsWithTypeIds(from: inputTokens)

    let mask = MLMultiArray.toIntArray(attentionMask)
    let types = MLMultiArray.toIntArray(tokenTypeIds)
    #expect(types.count == inputTokens.count)
    #expect(mask.contains(0))
    #expect(types.allSatisfy { $0 == 0 })
}

@Test
func bertTokenizerPairTypeIdsKeepOnlySecondSegmentActive() throws {
    let tokenizer = try BertTokenizer()
    let inputTokens = try tokenizer.convertTokensToIds(tokens: [
        "[CLS]", "hello", "[SEP]", "world", "[SEP]", "[PAD]",
    ])

    let (_, _, tokenTypeIds) = try tokenizer.buildModelInputsWithTypeIds(from: inputTokens)

    #expect(MLMultiArray.toIntArray(tokenTypeIds) == [0, 0, 0, 1, 1, 0])
}
#endif
