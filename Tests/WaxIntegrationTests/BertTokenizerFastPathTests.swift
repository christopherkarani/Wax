#if canImport(WaxVectorSearchMiniLM)
import Testing
@testable import WaxVectorSearchMiniLM

@Test("BertTokenizer tokenizeToIds matches tokenize+convert pipeline")
func bertTokenizerTokenizeToIdsMatchesLegacyPipeline() throws {
    let tokenizer = try BertTokenizer()
    let texts = [
        "Swift concurrency vector search performance optimization is critical for on-device RAG systems.",
        "Document 17 about Wax performance. Hybrid search fuses lexical and semantic signals.",
        "Numbers 12345, punctuation!, and unicode caf\u{00E9} should still tokenize consistently."
    ]

    for text in texts {
        let expected = try tokenizer.convertTokensToIds(tokens: tokenizer.tokenize(text: text))
        let actual = try tokenizer.tokenizeToIds(text: text)
        #expect(actual == expected)
    }
}
#endif
