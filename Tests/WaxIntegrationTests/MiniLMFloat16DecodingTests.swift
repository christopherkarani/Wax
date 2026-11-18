#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import CoreML
import Testing
@_spi(Testing) import WaxVectorSearchMiniLM

private struct DecodeTestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMFloat16DecodingPreservesNormalValues() throws {
    let values: [Float16] = [1.0, -2.0, 0.5, 65504.0]
    let array = try makeFloat16Array(rows: 1, cols: values.count, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: values.count)

    #expect(decoded.count == 1)
    #expect(decoded[0].count == values.count)
    for (expected, actual) in zip(values, decoded[0]) {
        #expect(actual == Float(expected))
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMFloat16DecodingPreservesSubnormalsAndSpecials() throws {
    let values: [Float16] = [
        Float16(bitPattern: 0x0001),
        Float16(bitPattern: 0x8001),
        .zero,
        Float16(bitPattern: 0x7C00),
        Float16(bitPattern: 0xFC00),
        Float16(bitPattern: 0x7E00),
    ]

    let array = try makeFloat16Array(rows: 1, cols: values.count, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: values.count)

    #expect(decoded.count == 1)
    for (expected, actual) in zip(values, decoded[0]) {
        if expected.isNaN {
            #expect(actual.isNaN)
            continue
        }
        if expected.isInfinite {
            #expect(actual.isInfinite)
            #expect(actual.sign == expected.sign)
            continue
        }
        #expect(actual == Float(expected))
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMDecodingRejectsUnsupportedOutputDataTypes() throws {
    let array = try MLMultiArray(shape: [1, 3], dataType: .int32)
    let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
    ptr[0] = 1
    ptr[1] = 2
    ptr[2] = 3

    #expect(throws: MiniLMEmbeddings.OutputError.unsupportedDataType(rawValue: MLMultiArrayDataType.int32.rawValue)) {
        try MiniLMEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 3)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMDecodingRejectsTokenEmbeddingShapedOutput() throws {
    // [batch, sequence, hidden] token embeddings must not be silently truncated to the
    // first token's vector.
    let array = try MLMultiArray(shape: [1, 4, 8], dataType: .float32)
    #expect(throws: MiniLMEmbeddings.OutputError.unexpectedShape(shape: [1, 4, 8], batchSize: 1, outputDimension: 8)) {
        try MiniLMEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 8)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMDecodingRejectsWrongEmbeddingDimension() throws {
    let array = try MLMultiArray(shape: [1, 6], dataType: .float32)
    #expect(throws: MiniLMEmbeddings.OutputError.unexpectedShape(shape: [1, 6], batchSize: 1, outputDimension: 8)) {
        try MiniLMEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 8)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMDecodingRejectsBatchSizeMismatch() throws {
    let array = try MLMultiArray(shape: [2, 8], dataType: .float32)
    #expect(throws: MiniLMEmbeddings.OutputError.unexpectedShape(shape: [2, 8], batchSize: 1, outputDimension: 8)) {
        try MiniLMEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 8)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMDecodingReadsBatchRowsInOrder() throws {
    let array = try MLMultiArray(shape: [2, 3], dataType: .float32)
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    for index in 0..<6 {
        ptr[index] = Float(index)
    }
    let decoded = try decode(array, batchSize: 2, outputDimension: 3)
    #expect(decoded == [[0, 1, 2], [3, 4, 5]])
}

@available(macOS 15.0, iOS 18.0, *)
private func decode(
    _ array: MLMultiArray,
    batchSize: Int,
    outputDimension: Int
) throws -> [[Float]] {
    try MiniLMEmbeddings._decodeEmbeddingsForTesting(
        array,
        batchSize: batchSize,
        outputDimension: outputDimension
    )
}

@available(macOS 15.0, iOS 18.0, *)
private func makeFloat16Array(rows: Int, cols: Int, values: [Float16]) throws -> MLMultiArray {
    let array = try MLMultiArray(
        shape: [NSNumber(value: rows), NSNumber(value: cols)],
        dataType: .float16
    )
    guard array.count == values.count else {
        throw DecodeTestError("Shape \(rows)x\(cols) does not match values count \(values.count)")
    }
    let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: values.count)
    for index in 0..<values.count {
        ptr[index] = values[index]
    }
    return array
}
#endif
