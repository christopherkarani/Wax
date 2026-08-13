#if canImport(CoreML)
import CoreML
import Testing
import WaxCore
import WaxVectorSearch
@testable import WaxVectorSearchArctic
@_spi(Testing) import WaxVectorSearchArctic

private struct ArcticDecodeTestError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private let arcticDimension = 384
private let decodeTolerance: Float = 1e-5

@Suite("ArcticDecodingTests")
struct ArcticDecodingTests {
    @Test func arcticDecodingContiguousFloat32_1x384() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let values = ramp(count: arcticDimension, scale: 0.01, offset: 0.25)
        let array = try makeContiguousArray(shape: [1, arcticDimension], dataType: .float32, values: values)
        let decoded = try decode(array, batchSize: 1, outputDimension: arcticDimension)
        try assertDecodedEquals([values], decoded)
    }

    @Test func arcticDecodingRejectsUnsupportedOutputDataTypes() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let array = try MLMultiArray(
            shape: [NSNumber(value: 1), NSNumber(value: arcticDimension)],
            dataType: .int32
        )
        try assertDecodeRejected(
            array,
            batchSize: 1,
            outputDimension: arcticDimension
        )
    }

    @Test func arcticDecodingRejectsTokenSequenceShapeInsteadOfFlatFallback() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let sequenceLength = 8
        let values = ramp(count: sequenceLength * arcticDimension, scale: 0.01, offset: 0.2)
        let array = try makeContiguousArray(
            shape: [1, sequenceLength, arcticDimension],
            dataType: .float32,
            values: values
        )
        try assertDecodeRejected(
            array,
            batchSize: 1,
            outputDimension: arcticDimension
        )
    }

    @Test func arcticDecodingRejectsRank4EvenWhenElementCountMatches() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let values = ramp(count: arcticDimension, scale: 0.01, offset: 0.2)
        let array = try makeContiguousArray(shape: [1, 1, 1, arcticDimension], dataType: .float32, values: values)
        try assertDecodeRejected(
            array,
            batchSize: 1,
            outputDimension: arcticDimension
        )
    }

    @Test func arcticDecodingRejectsWidthMismatchVersusOutputDimension() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let array = try makeContiguousArray(
            shape: [1, 10],
            dataType: .float32,
            values: ramp(count: 10, scale: 1, offset: 0)
        )
        try assertDecodeRejected(
            array,
            batchSize: 1,
            outputDimension: arcticDimension
        )
    }

    @Test func arcticDecodingRejectsZeroColumnStride() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let array = try makeShapeOnlyArray(
            shape: [1, arcticDimension],
            strides: [arcticDimension, 0],
            dataType: .float32
        )
        try assertDecodeRejected(
            array,
            batchSize: 1,
            outputDimension: arcticDimension
        )
    }

    @Test func arcticProviderBoundaryRejectsZeroVector() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let zeros = [Float](repeating: 0, count: arcticDimension)
        do {
            _ = try ArcticEmbedder._validatedProducedVectorForTesting(zeros, dimensions: arcticDimension)
            throw ArcticDecodeTestError("expected Arctic provider boundary to reject zeros")
        } catch let error as WaxError {
            guard case .invalidEmbedding = error else {
                throw ArcticDecodeTestError("expected WaxError.invalidEmbedding, got \(error)")
            }
        }
    }

    @Test func arcticProviderBoundaryRejectsNaN() throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        var values = ramp(count: arcticDimension, scale: 0.01, offset: 0.3)
        values[7] = .nan
        do {
            _ = try ArcticEmbedder._validatedProducedVectorForTesting(values, dimensions: arcticDimension)
            throw ArcticDecodeTestError("expected Arctic provider boundary to reject NaN")
        } catch let error as WaxError {
            guard case .invalidEmbedding = error else {
                throw ArcticDecodeTestError("expected WaxError.invalidEmbedding, got \(error)")
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
    try ArcticEmbeddings._decodeEmbeddingsForTesting(
        array,
        batchSize: batchSize,
        outputDimension: outputDimension
    )
}

@available(macOS 15.0, iOS 18.0, *)
private func assertDecodeRejected(
    _ array: MLMultiArray,
    batchSize: Int,
    outputDimension: Int
) throws {
    do {
        _ = try ArcticEmbeddings._decodeEmbeddingsForTesting(
            array,
            batchSize: batchSize,
            outputDimension: outputDimension
        )
        throw ArcticDecodeTestError("decodeEmbeddings succeeded for unexpected Arctic output")
    } catch let error as ArcticEmbeddings.DecodeError {
        guard case let .unexpectedOutput(shape, strides, dataType, batch, dimension) = error else {
            throw ArcticDecodeTestError("DecodeError was not unexpectedOutput: \(error)")
        }
        #expect(shape == array.shape.map(\.intValue))
        #expect(strides == array.strides.map(\.intValue))
        #expect(!dataType.isEmpty)
        #expect(batch == batchSize)
        #expect(dimension == outputDimension)
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func assertDecodedEquals(_ expected: [[Float]], _ actual: [[Float]]) throws {
    #expect(actual.count == expected.count)
    for (expectedRow, actualRow) in zip(expected, actual) {
        #expect(actualRow.count == expectedRow.count)
        for (expectedValue, actualValue) in zip(expectedRow, actualRow) {
            #expect(abs(expectedValue - actualValue) <= decodeTolerance)
        }
    }
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
        throw ArcticDecodeTestError("Shape \(shape) count \(array.count) does not match values \(values.count)")
    }
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    for (index, value) in values.enumerated() {
        ptr[index] = value
    }
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

private func ramp(count: Int, scale: Float, offset: Float) -> [Float] {
    (0..<count).map { offset + Float($0) * scale }
}
#endif
