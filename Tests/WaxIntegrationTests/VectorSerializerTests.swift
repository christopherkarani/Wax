import Foundation
import Testing
@testable import Wax
@testable import WaxVectorSearch
import WaxCore

// MARK: - detectEncoding

@Test func detectEncodingUSearch() throws {
    // Build a minimal valid header with encoding = 1 (uSearch)
    let header = buildMinimalHeader(encoding: 1)
    let encoding = try VectorSerializer.detectEncoding(from: header)
    #expect(encoding == .uSearch)
}

@Test func legacyUSearchVectorSegmentRequiresRebuild() throws {
    let data = buildLegacyUSearchSegment(payload: Data([0x01, 0x02, 0x03, 0x04]))

    do {
        _ = try VectorSerializer.decodeVecSegment(from: data)
        Issue.record("Expected legacy USearch vector segment to require rebuild")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Expected invalidToc, got \(error)")
            return
        }
        #expect(reason.contains("Legacy USearch vector index is unsupported"))
        #expect(reason.contains("rebuild the vector index"))
    }
}

@Test func detectEncodingMetal() throws {
    let header = buildMinimalHeader(encoding: 2)
    let encoding = try VectorSerializer.detectEncoding(from: header)
    #expect(encoding == .metal)
}

@Test func detectEncodingTooSmallThrows() {
    let data = Data([0x4D, 0x56, 0x32]) // only 3 bytes
    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.detectEncoding(from: data)
    }
}

@Test func detectEncodingBadMagicThrows() {
    var data = Data(repeating: 0, count: 8)
    data[0] = 0xFF // wrong magic
    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.detectEncoding(from: data)
    }
}

@Test func detectEncodingBadVersionThrows() {
    var data = Data([0x4D, 0x56, 0x32, 0x56]) // correct magic
    // version = 99 (little-endian)
    data.append(contentsOf: [99, 0])
    data.append(1) // encoding
    data.append(0) // padding
    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.detectEncoding(from: data)
    }
}

@Test func detectEncodingInvalidEncodingThrows() {
    var data = Data([0x4D, 0x56, 0x32, 0x56]) // correct magic
    data.append(contentsOf: [1, 0]) // version = 1
    data.append(99) // invalid encoding
    data.append(0)
    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.detectEncoding(from: data)
    }
}

// MARK: - Metal segment round-trip

@Test func metalSegmentDecodeRoundTrip() throws {
    let vectors: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
    let frameIds: [UInt64] = [100, 200]
    let dimension: UInt32 = 3
    let vectorCount: UInt64 = 2

    let data = buildMetalSegment(
        vectors: vectors,
        frameIds: frameIds,
        dimension: dimension,
        vectorCount: vectorCount,
        similarity: 0 // cosine
    )

    let payload = try VectorSerializer.decodeVecSegment(from: data)
    guard case .metal(let info, let decodedVectors, let decodedFrameIds) = payload else {
        Issue.record("Expected metal payload")
        return
    }

    #expect(info.dimension == dimension)
    #expect(info.vectorCount == vectorCount)
    #expect(decodedVectors.count == vectors.count)
    for (a, b) in zip(decodedVectors, vectors) {
        #expect(abs(a - b) < 1e-6)
    }
    #expect(decodedFrameIds == frameIds)
}

@Test func flatSegmentDecodeRejectsVectorByteCountOverflow() throws {
    let data = buildFlatHeaderOnlySegment(
        dimension: UInt32.max,
        vectorCount: UInt64(Int.max / 2),
        payloadLength: 0
    )

    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.decodeVecSegment(from: data)
    }
}

@Test func flatVectorSerializationRejectsDuplicateFrameIds() throws {
    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.serializeFlatVectors(
            [1.0, 0.0, 0.0, 1.0],
            frameIds: [7, 7],
            metric: .cosine,
            dimensions: 2
        )
    }
}

@Test func metalSegmentDecodeRejectsDuplicateFrameIds() throws {
    let data = buildMetalSegment(
        vectors: [1.0, 0.0, 0.0, 1.0],
        frameIds: [7, 7],
        dimension: 2,
        vectorCount: 2,
        similarity: 0
    )

    #expect(throws: WaxError.self) {
        _ = try VectorSerializer.decodeVecSegment(from: data)
    }
}

// MARK: - Helpers

private func buildMinimalHeader(encoding: UInt8) -> Data {
    var data = Data()
    data.append(contentsOf: [0x4D, 0x56, 0x32, 0x56]) // magic "MV2V"
    var version = UInt16(1).littleEndian
    withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
    data.append(encoding)
    data.append(0) // similarity = cosine
    return data
}

private func buildLegacyUSearchSegment(payload: Data) -> Data {
    var encoder = BinaryEncoder()
    encoder.encodeFixedBytes(Data([0x4D, 0x56, 0x32, 0x56]))
    encoder.encode(UInt16(1))
    encoder.encode(UInt8(1))
    encoder.encode(UInt8(0))
    encoder.encode(UInt32(2))
    encoder.encode(UInt64(1))
    encoder.encode(UInt64(payload.count))
    encoder.encodeFixedBytes(Data(repeating: 0, count: 8))
    var data = encoder.data
    data.append(payload)
    return data
}

private func buildFlatHeaderOnlySegment(
    dimension: UInt32,
    vectorCount: UInt64,
    payloadLength: UInt64
) -> Data {
    var encoder = BinaryEncoder()
    encoder.encodeFixedBytes(Data([0x4D, 0x56, 0x32, 0x56]))
    encoder.encode(UInt16(1))
    encoder.encode(UInt8(3))
    encoder.encode(UInt8(0))
    encoder.encode(dimension)
    encoder.encode(vectorCount)
    encoder.encode(payloadLength)
    encoder.encodeFixedBytes(Data(repeating: 0, count: 8))
    return encoder.data
}

private func buildMetalSegment(
    vectors: [Float],
    frameIds: [UInt64],
    dimension: UInt32,
    vectorCount: UInt64,
    similarity: UInt8
) -> Data {
    var encoder = BinaryEncoder()
    // Header: magic(4) + version(2) + encoding(1) + similarity(1) + dimension(4) + vectorCount(8) + payloadLength(8) + reserved(8) = 36
    encoder.encodeFixedBytes(Data([0x4D, 0x56, 0x32, 0x56])) // magic
    encoder.encode(UInt16(1)) // version
    encoder.encode(UInt8(2)) // encoding = metal
    encoder.encode(similarity) // similarity
    encoder.encode(dimension)
    encoder.encode(vectorCount)
    let vectorBytes = vectors.count * MemoryLayout<Float>.stride
    encoder.encode(UInt64(vectorBytes)) // payloadLength = vector data bytes
    encoder.encodeFixedBytes(Data(repeating: 0, count: 8)) // reserved

    // Vector data
    vectors.withUnsafeBufferPointer { buf in
        encoder.encodeFixedBytes(Data(buffer: buf))
    }

    // FrameId length + data
    let frameIdBytes = frameIds.count * MemoryLayout<UInt64>.stride
    encoder.encode(UInt64(frameIdBytes))
    frameIds.withUnsafeBufferPointer { buf in
        encoder.encodeFixedBytes(Data(buffer: buf))
    }

    return encoder.data
}
