#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import CoreML
import Testing
@testable import WaxVectorSearchMiniLM

@Test func multiArrayBatchBuilderUsesDynamicSequenceLength() throws {
    let batch: [[Int]] = [
        [101, 102, 103],
        [201, 202],
    ]

    let array = try MLMultiArray.from(batch: batch)

    #expect(array.dataType == .int32)
    #expect(array.shape.map { $0.intValue } == [2, 3])
    #expect(MLMultiArray.toIntArray(array) == [101, 102, 103, 201, 202, 0])
}

@Test func multiArrayBatchBuilderRespectsExplicitSequenceLength() throws {
    let batch: [[Int]] = [
        [101, 102, 103],
        [201, 202],
    ]

    let array = try MLMultiArray.from(batch: batch, sequenceLength: 4)

    #expect(array.shape.map { $0.intValue } == [2, 4])
    #expect(MLMultiArray.toIntArray(array) == [101, 102, 103, 0, 201, 202, 0, 0])
}

@Test func multiArrayBatchBuilderTruncatesWhenSequenceLengthIsShorter() throws {
    let batch: [[Int]] = [
        [101, 102, 103],
        [201, 202],
    ]

    let array = try MLMultiArray.from(batch: batch, sequenceLength: 2)

    #expect(array.shape.map { $0.intValue } == [2, 2])
    #expect(MLMultiArray.toIntArray(array) == [101, 102, 201, 202])
}
#endif
