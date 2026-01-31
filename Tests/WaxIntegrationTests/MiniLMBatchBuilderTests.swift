#if canImport(WaxVectorSearchMiniLM)
import CoreML
import Testing
@testable import WaxVectorSearchMiniLM

@Test("BertTokenizer builds batched inputs with dynamic sequence length")
func testBatchInputsShapeAndMask() throws {
    let tokenizer = BertTokenizer()
    let inputs = tokenizer.buildBatchInputs(sentences: [
        "hello world",
        "this is a longer sentence to ensure different lengths",
    ])

    let shape = inputs.inputIds.shape.map { $0.intValue }
    #expect(shape.count == 2)
    #expect(shape[0] == 2)
    #expect(shape[1] == inputs.sequenceLength)
    #expect(inputs.sequenceLength == (inputs.lengths.max() ?? 0))

    let mask = MLMultiArray.toIntArray(inputs.attentionMask)
    for row in 0..<2 {
        let rowLength = inputs.lengths[row]
        for col in 0..<inputs.sequenceLength {
            let value = mask[row * inputs.sequenceLength + col]
            if col < rowLength {
                #expect(value == 1)
            } else {
                #expect(value == 0)
            }
        }
    }
}

@Test("BertTokenizer respects maxSequenceLength in batch inputs")
func testBatchInputsRespectsMaxSequenceLength() throws {
    let tokenizer = BertTokenizer()
    let longSentence = Array(repeating: "token", count: 64).joined(separator: " ")
    let inputs = tokenizer.buildBatchInputs(sentences: [longSentence], maxSequenceLength: 8)

    #expect(inputs.sequenceLength == 8)
    #expect(inputs.lengths.allSatisfy { $0 <= 8 })

    let mask = MLMultiArray.toIntArray(inputs.attentionMask)
    for col in 0..<inputs.sequenceLength {
        let value = mask[col]
        if col < inputs.lengths[0] {
            #expect(value == 1)
        } else {
            #expect(value == 0)
        }
    }
}
#endif
