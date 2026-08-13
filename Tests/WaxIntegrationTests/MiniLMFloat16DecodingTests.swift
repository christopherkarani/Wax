#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import CoreML
import Testing
import WaxCore
import WaxVectorSearch
@_spi(Testing) import WaxVectorSearchMiniLM

private struct DecodeTestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

private let miniLMDimension = 384
private let decodeTolerance: Float = 1e-5

@Suite("MiniLMFloat16DecodingTests")
struct MiniLMFloat16DecodingTests {
@Test func miniLMFloat16DecodingPreservesNormalValues() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values: [Float16] = [1.0, -2.0, 0.5, 65504.0]
    let array = try makeFloat16Array(rows: 1, cols: values.count, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: values.count)

    #expect(decoded.count == 1)
    #expect(decoded[0].count == values.count)
    for (expected, actual) in zip(values, decoded[0]) {
        #expect(actual == Float(expected))
    }
}

@Test func miniLMFloat16DecodingPreservesSubnormalsAndSpecials() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
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

@Test func miniLMDecodingRejectsUnsupportedOutputDataTypes() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let array = try MLMultiArray(shape: [1, 3], dataType: .int32)
    let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
    ptr[0] = 1
    ptr[1] = 2
    ptr[2] = 3

    try assertDecodeRejected(
        array,
        batchSize: 1,
        outputDimension: 3,
        expectedBatch: 1,
        expectedDimension: 3
    )
}

@Test func miniLMPreTokenizedBatchSizeUsesInputRows() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let inputIds = try MLMultiArray(shape: [2, 3], dataType: .int32)
    let attentionMask = try MLMultiArray(shape: [2, 3], dataType: .int32)

    let batchSize = MiniLMEmbeddings._preTokenizedBatchSizeForTesting(
        inputIds: inputIds,
        attentionMask: attentionMask
    )

    #expect(batchSize == 2)
}

@Test func miniLMPreTokenizedBatchSizeRejectsMismatchedInputRows() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let inputIds = try MLMultiArray(shape: [2, 3], dataType: .int32)
    let attentionMask = try MLMultiArray(shape: [1, 3], dataType: .int32)

    let batchSize = MiniLMEmbeddings._preTokenizedBatchSizeForTesting(
        inputIds: inputIds,
        attentionMask: attentionMask
    )

    #expect(batchSize == nil)
}

@Test func miniLMDecodingContiguousFloat32_1x384() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.01, offset: 0.25)
    let array = try makeContiguousArray(shape: [1, miniLMDimension], dataType: .float32, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    try assertDecodedEquals([values], decoded)
}

@Test func miniLMDecodingContiguousFloat16_1x384() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.02, offset: -1.5)
    let array = try makeContiguousArray(shape: [1, miniLMDimension], dataType: .float16, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    let expected = values.map { Float(Float16($0)) }
    try assertDecodedEquals([expected], decoded)
}

@Test func miniLMDecodingNonContiguousFloat32Strides() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.005, offset: 1.0)
    let array = try makeStridedArray(
        shape: [1, miniLMDimension],
        strides: [miniLMDimension * 2, 2],
        dataType: .float32,
        rows: [values]
    )
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    try assertDecodedEquals([values], decoded)
}

@Test func miniLMDecodingNonContiguousFloat16Strides() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.003, offset: -0.25)
    let array = try makeStridedArray(
        shape: [1, miniLMDimension],
        strides: [miniLMDimension * 2, 2],
        dataType: .float16,
        rows: [values]
    )
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    let expected = values.map { Float(Float16($0)) }
    try assertDecodedEquals([expected], decoded)
}

@Test func miniLMDecodingShape_1_1_384() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.004, offset: 0.5)
    let array = try makeContiguousArray(shape: [1, 1, miniLMDimension], dataType: .float32, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    try assertDecodedEquals([values], decoded)
}

@Test func miniLMDecodingShape_1_384_1() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.006, offset: -0.75)
    let array = try makeContiguousArray(shape: [1, miniLMDimension, 1], dataType: .float32, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    try assertDecodedEquals([values], decoded)
}

@Test func miniLMDecodingTwoRowBatchFloat32AndFloat16() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let row0 = ramp(count: miniLMDimension, scale: 0.001, offset: 0.1)
    let row1 = ramp(count: miniLMDimension, scale: 0.002, offset: 2.0)

    let float32 = try makeContiguousArray(
        shape: [2, miniLMDimension],
        dataType: .float32,
        values: row0 + row1
    )
    let decoded32 = try decode(float32, batchSize: 2, outputDimension: miniLMDimension)
    try assertDecodedEquals([row0, row1], decoded32)

    let float16 = try makeContiguousArray(
        shape: [2, miniLMDimension],
        dataType: .float16,
        values: row0 + row1
    )
    let decoded16 = try decode(float16, batchSize: 2, outputDimension: miniLMDimension)
    let expected16 = [row0, row1].map { $0.map { Float(Float16($0)) } }
    try assertDecodedEquals(expected16, decoded16)
}

@Test func miniLMDecodingRejectsRank4EvenWhenElementCountMatches() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let values = ramp(count: miniLMDimension, scale: 0.01, offset: 0.2)
    let array = try makeContiguousArray(shape: [1, 1, 1, miniLMDimension], dataType: .float32, values: values)
    try assertDecodeRejected(
        array,
        batchSize: 1,
        outputDimension: miniLMDimension,
        expectedBatch: 1,
        expectedDimension: miniLMDimension
    )
}

@Test func miniLMDecodingRejectsWidthMismatchVersusOutputDimension() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let array = try makeContiguousArray(
        shape: [1, 10],
        dataType: .float32,
        values: ramp(count: 10, scale: 1, offset: 0)
    )
    try assertDecodeRejected(
        array,
        batchSize: 1,
        outputDimension: miniLMDimension,
        expectedBatch: 1,
        expectedDimension: miniLMDimension
    )
}

@Test func miniLMDecodingRejectsZeroColumnStride() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let array = try makeShapeOnlyArray(
        shape: [1, miniLMDimension],
        strides: [miniLMDimension, 0],
        dataType: .float32
    )
    try assertDecodeRejected(
        array,
        batchSize: 1,
        outputDimension: miniLMDimension,
        expectedBatch: 1,
        expectedDimension: miniLMDimension
    )
}

@Test func miniLMDecodingRejectsNegativeColumnStride() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let array = try makeShapeOnlyArray(
        shape: [1, miniLMDimension],
        strides: [miniLMDimension, -1],
        dataType: .float32
    )
    try assertDecodeRejected(
        array,
        batchSize: 1,
        outputDimension: miniLMDimension,
        expectedBatch: 1,
        expectedDimension: miniLMDimension
    )
}

@Test func miniLMProviderBoundaryRejectsDecodedNaN() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    var values = ramp(count: miniLMDimension, scale: 0.01, offset: 0.3)
    values[7] = .nan
    let array = try makeContiguousArray(shape: [1, miniLMDimension], dataType: .float32, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    try assertInvalidEmbedding(decoded[0])
}

@Test func miniLMProviderBoundaryRejectsDecodedInfinity() throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    var values = ramp(count: miniLMDimension, scale: 0.01, offset: 0.3)
    values[11] = .infinity
    let array = try makeContiguousArray(shape: [1, miniLMDimension], dataType: .float16, values: values)
    let decoded = try decode(array, batchSize: 1, outputDimension: miniLMDimension)
    try assertInvalidEmbedding(decoded[0])
}

@Test func miniLMEmbedderProducesFiniteNonZeroVector() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let embedder = try MiniLMEmbedder()
    let vector = try await embedder.embed("hello world")
    #expect(vector.count == miniLMDimension)
    let allFinite = vector.allSatisfy(\.isFinite)
    #expect(allFinite)
    let magnitudeSquared = vector.reduce(Float.zero) { $0 + $1 * $1 }
    #expect(magnitudeSquared > 0)
    #expect(abs(magnitudeSquared - 1) < 0.02)
}

@Test func embeddingValidationRejectsZeroNormEvenWhenRequireNonZeroIsFalse() throws {
    let zeros = [Float](repeating: 0, count: miniLMDimension)
    do {
        try EmbeddingValidation.validate(zeros, dimensions: miniLMDimension, requireNonZero: false)
        throw DecodeTestError("expected EmbeddingValidation to reject a zero-norm vector")
    } catch let error as WaxError {
        guard case .invalidEmbedding = error else {
            throw DecodeTestError("expected WaxError.invalidEmbedding, got \(error)")
        }
    }
}

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
private func assertDecodeRejected(
    _ array: MLMultiArray,
    batchSize: Int,
    outputDimension: Int,
    expectedBatch: Int,
    expectedDimension: Int
) throws {
    do {
        _ = try MiniLMEmbeddings._decodeEmbeddingsForTesting(
            array,
            batchSize: batchSize,
            outputDimension: outputDimension
        )
        throw DecodeTestError("decodeEmbeddings succeeded for unexpected output")
    } catch let error as MiniLMEmbeddings.DecodeError {
        guard case let .unexpectedOutput(shape, strides, dataType, batch, dimension) = error else {
            throw DecodeTestError("DecodeError was not unexpectedOutput: \(error)")
        }
        #expect(shape == array.shape.map(\.intValue))
        #expect(strides == array.strides.map(\.intValue))
        #expect(!dataType.isEmpty)
        #expect(batch == expectedBatch)
        #expect(dimension == expectedDimension)
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func assertInvalidEmbedding(_ vector: [Float]) throws {
    do {
        try EmbeddingValidation.validate(vector, dimensions: miniLMDimension, requireNonZero: true)
        throw DecodeTestError("expected EmbeddingValidation to throw for non-finite payload")
    } catch let error as WaxError {
        guard case .invalidEmbedding = error else {
            throw DecodeTestError("expected WaxError.invalidEmbedding, got \(error)")
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func assertDecodedEquals(_ expected: [[Float]], _ actual: [[Float]]) throws {
    #expect(actual.count == expected.count)
    for (expectedRow, actualRow) in zip(expected, actual) {
        #expect(actualRow.count == expectedRow.count)
        for (expectedValue, actualValue) in zip(expectedRow, actualRow) {
            if expectedValue.isNaN {
                #expect(actualValue.isNaN)
                continue
            }
            #expect(abs(expectedValue - actualValue) <= decodeTolerance)
        }
    }
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

@available(macOS 15.0, iOS 18.0, *)
private func makeContiguousArray(
    shape: [Int],
    dataType: MLMultiArrayDataType,
    values: [Float]
) throws -> MLMultiArray {
    let array = try MLMultiArray(
        shape: shape.map { NSNumber(value: $0) },
        dataType: dataType
    )
    guard array.count == values.count else {
        throw DecodeTestError("Shape \(shape) count \(array.count) does not match values \(values.count)")
    }
    write(values: values, to: array, dataType: dataType)
    return array
}

@available(macOS 15.0, iOS 18.0, *)
private func makeShapeOnlyArray(
    shape: [Int],
    strides: [Int],
    dataType: MLMultiArrayDataType
) throws -> MLMultiArray {
    let byteCount = 64
    let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    return try MLMultiArray(
        dataPointer: raw,
        shape: shape.map { NSNumber(value: $0) },
        dataType: dataType,
        strides: strides.map { NSNumber(value: $0) },
        deallocator: { $0.deallocate() }
    )
}

@available(macOS 15.0, iOS 18.0, *)
private func makeStridedArray(
    shape: [Int],
    strides: [Int],
    dataType: MLMultiArrayDataType,
    rows: [[Float]]
) throws -> MLMultiArray {
    let bufferCount = zip(shape, strides).map { max(0, $0 - 1) * $1 }.reduce(0, +) + 1
    let byteCount: Int
    switch dataType {
    case .float32:
        byteCount = bufferCount * MemoryLayout<Float>.stride
    case .float16:
        byteCount = bufferCount * MemoryLayout<UInt16>.stride
    default:
        throw DecodeTestError("unsupported fixture dtype")
    }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

    let array = try MLMultiArray(
        dataPointer: raw,
        shape: shape.map { NSNumber(value: $0) },
        dataType: dataType,
        strides: strides.map { NSNumber(value: $0) },
        deallocator: { $0.deallocate() }
    )

    for (row, values) in rows.enumerated() {
        for (col, value) in values.enumerated() {
            let index = row * strides[0] + col * strides[1]
            write(value: value, at: index, in: array, dataType: dataType, capacity: bufferCount)
        }
    }
    return array
}

@available(macOS 15.0, iOS 18.0, *)
private func write(values: [Float], to array: MLMultiArray, dataType: MLMultiArrayDataType) {
    for (index, value) in values.enumerated() {
        write(value: value, at: index, in: array, dataType: dataType, capacity: array.count)
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func write(
    value: Float,
    at index: Int,
    in array: MLMultiArray,
    dataType: MLMultiArrayDataType,
    capacity: Int
) {
    switch dataType {
    case .float32:
        array.dataPointer.bindMemory(to: Float.self, capacity: capacity)[index] = value
    case .float16:
        array.dataPointer.bindMemory(to: Float16.self, capacity: capacity)[index] = Float16(value)
    default:
        break
    }
}

private func ramp(count: Int, scale: Float, offset: Float) -> [Float] {
    (0..<count).map { offset + Float($0) * scale }
}
#endif
