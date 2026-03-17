#if canImport(WaxBertTokenizer)
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
#endif
