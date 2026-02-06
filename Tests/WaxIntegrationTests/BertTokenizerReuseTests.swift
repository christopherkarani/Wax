#if canImport(WaxVectorSearchMiniLM)
import Testing
@testable import WaxVectorSearchMiniLM

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
#endif
