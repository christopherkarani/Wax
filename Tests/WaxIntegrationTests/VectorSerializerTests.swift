import Foundation
import Testing
@testable import WaxCore
@testable import WaxVectorSearch

// MARK: - Helpers

private func vecHeader(
    encoding: UInt8,
    similarity: UInt8,
    dimension: UInt32,
    vectorCount: UInt64,
    payloadLength: UInt64,
    reserved: Data = Data(repeating: 0, count: 8),
    magic: Data = Data([0x4D, 0x56, 0x32, 0x56]),
    version: UInt16 = 1
) -> Data {
    var encoder = BinaryEncoder()
    encoder.encodeFixedBytes(magic)
    encoder.encode(version)
    encoder.encode(encoding)
    encoder.encode(similarity)
    encoder.encode(dimension)
    encoder.encode(vectorCount)
    encoder.encode(payloadLength)
    encoder.encodeFixedBytes(reserved)
    return encoder.data
}

private func floatData(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func uint64Data(_ values: [UInt64]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

// MARK: - Existing tests

@Test
func vectorSerializerDetectEncodingRejectsMalformedHeaders() {
    do {
        _ = try VectorSerializer.detectEncoding(from: Data([1, 2, 3]))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("too small"))
    } catch {
        #expect(Bool(false))
    }

    do {
        _ = try VectorSerializer.detectEncoding(from: vecHeader(encoding: 1, similarity: 0, dimension: 1, vectorCount: 0, payloadLength: 0, magic: Data("BAD!".utf8)))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("magic mismatch"))
    } catch {
        #expect(Bool(false))
    }

    do {
        _ = try VectorSerializer.detectEncoding(from: vecHeader(encoding: 1, similarity: 0, dimension: 1, vectorCount: 0, payloadLength: 0, version: 2))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("unsupported vec segment version"))
    } catch {
        #expect(Bool(false))
    }

    do {
        _ = try VectorSerializer.detectEncoding(from: vecHeader(encoding: 99, similarity: 0, dimension: 1, vectorCount: 0, payloadLength: 0))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("unsupported vec segment encoding"))
    } catch {
        #expect(Bool(false))
    }
}

@Test
func vectorSerializerDecodesUSearchAndMetalPayloads() throws {
    let uSearchPayload = Data([0xAA, 0xBB, 0xCC, 0xDD])
    let uSearchData = vecHeader(
        encoding: VectorSerializer.VecEncoding.uSearch.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 3,
        vectorCount: 2,
        payloadLength: UInt64(uSearchPayload.count)
    ) + uSearchPayload

    #expect(try VectorSerializer.detectEncoding(from: uSearchData) == .uSearch)
    let decodedUSearch = try VectorSerializer.decodeUSearchPayload(from: uSearchData)
    #expect(decodedUSearch.info.dimension == 3)
    #expect(decodedUSearch.info.vectorCount == 2)
    #expect(decodedUSearch.payload == uSearchPayload)

    let vectors: [Float] = [1.5, -2.0]
    let frameIds: [UInt64] = [42]
    var metalData = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.dot.rawValue,
        dimension: 2,
        vectorCount: 1,
        payloadLength: UInt64(vectors.count * MemoryLayout<Float>.stride)
    )
    metalData.append(floatData(vectors))
    metalData.append(uint64Data([UInt64(frameIds.count * MemoryLayout<UInt64>.stride)]))
    metalData.append(uint64Data(frameIds))

    #expect(try VectorSerializer.detectEncoding(from: metalData) == .metal)
    let decodedMetal = try VectorSerializer.decodeVecSegment(from: metalData)
    guard case .metal(let info, let decodedVectors, let decodedFrameIds) = decodedMetal else {
        #expect(Bool(false))
        return
    }
    #expect(info.similarity == .dot)
    #expect(info.dimension == 2)
    #expect(decodedVectors == vectors)
    #expect(decodedFrameIds == frameIds)

    do {
        _ = try VectorSerializer.decodeUSearchPayload(from: metalData)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("encoding is metal"))
    } catch {
        #expect(Bool(false))
    }
}

@Test
func vectorSerializerRejectsInvalidReservedBytes() {
    let badReserved = vecHeader(
        encoding: VectorSerializer.VecEncoding.uSearch.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 1,
        vectorCount: 0,
        payloadLength: 0,
        reserved: Data(repeating: 1, count: 8)
    )

    do {
        _ = try VectorSerializer.decodeVecSegment(from: badReserved)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("reserved bytes must be zero"))
    } catch {
        #expect(Bool(false))
    }
}

// MARK: - Phase 6C: Additional VectorSerializer coverage

/// detectEncoding succeeds for a well-formed USearch header (encoding byte = 1).
@Test
func vectorSerializerDetectEncodingSucceedsForUSearch() throws {
    let data = vecHeader(
        encoding: VectorSerializer.VecEncoding.uSearch.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 4,
        vectorCount: 0,
        payloadLength: 0
    )
    let encoding = try VectorSerializer.detectEncoding(from: data)
    #expect(encoding == .uSearch)
}

/// detectEncoding succeeds for a well-formed Metal header (encoding byte = 2).
@Test
func vectorSerializerDetectEncodingSucceedsForMetal() throws {
    let data = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 4,
        vectorCount: 0,
        payloadLength: 0
    )
    let encoding = try VectorSerializer.detectEncoding(from: data)
    #expect(encoding == .metal)
}

/// decodeVecSegment for a USearch payload with length mismatch must throw.
@Test
func vectorSerializerUSearchLengthMismatchThrows() {
    // Header says payload is 4 bytes, but we append only 2 bytes.
    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.uSearch.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 1,
        vectorCount: 0,
        payloadLength: 4
    )
    let tooShort = header + Data([0xAA, 0xBB]) // only 2 bytes instead of 4

    do {
        _ = try VectorSerializer.decodeVecSegment(from: tooShort)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("length mismatch"))
    } catch {
        #expect(Bool(false))
    }
}

/// decodeVecSegment for a Metal segment where vector data length != vectorCount * dims * 4 must throw.
@Test
func vectorSerializerMetalVectorLengthMismatchThrows() {
    // Claim vectorCount=1, dimension=2 → expected vector bytes = 1*2*4 = 8.
    // But payloadLength says 12 (mismatch).
    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 2,
        vectorCount: 1,
        payloadLength: 12 // wrong: should be 8
    )
    // Append enough data so the check reaches the vector-length guard.
    let garbage = header + Data(repeating: 0, count: 40)

    do {
        _ = try VectorSerializer.decodeVecSegment(from: garbage)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("length mismatch") || reason.contains("vec vector"))
    } catch {
        #expect(Bool(false))
    }
}

/// decodeVecSegment for a Metal segment missing the frameId-length UInt64 must throw.
@Test
func vectorSerializerMetalMissingFrameIdLengthThrows() {
    // vectorCount=1, dimension=1 → vector bytes = 4.
    // We append only the 4 vector bytes, omitting the frameId-length field.
    let vectors: [Float] = [1.0]
    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 1,
        vectorCount: 1,
        payloadLength: UInt64(MemoryLayout<Float>.stride)
    )
    let incomplete = header + floatData(vectors) // no frameId length field

    do {
        _ = try VectorSerializer.decodeVecSegment(from: incomplete)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("missing frameIds length") || reason.contains("missing frameId"))
    } catch {
        #expect(Bool(false))
    }
}

/// decodeVecSegment for a Metal segment where frameId byte count mismatches vectorCount must throw.
@Test
func vectorSerializerMetalFrameIdCountMismatchThrows() {
    // vectorCount=2, dimension=1 → vector bytes = 8, expected frameId bytes = 2*8 = 16.
    // We encode frameIdLength = 8 (only 1 frameId, not 2).
    let vectors: [Float] = [1.0, 2.0]
    let vectorBytes = floatData(vectors)
    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 1,
        vectorCount: 2,
        payloadLength: UInt64(vectorBytes.count)
    )
    // frameIdLength = 8 (wrong: should be 16 for 2 frameIds)
    var data = header + vectorBytes + uint64Data([8])
    // Append the one frameId.
    data += uint64Data([99])

    do {
        _ = try VectorSerializer.decodeVecSegment(from: data)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("length mismatch") || reason.contains("frameId"))
    } catch {
        #expect(Bool(false))
    }
}

/// decodeVecSegment for a Metal segment with total length exceeding the declared fields must throw.
@Test
func vectorSerializerMetalTotalLengthMismatchThrows() {
    // Valid header + valid vector + valid frameId length + valid frameId but with extra trailing bytes.
    let vectors: [Float] = [1.0]
    let frameIds: [UInt64] = [42]
    let vectorBytes = floatData(vectors)
    let frameIdBytes = uint64Data(frameIds)
    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 1,
        vectorCount: 1,
        payloadLength: UInt64(vectorBytes.count)
    )
    // Correct structure but with 4 extra trailing bytes.
    var data = header + vectorBytes + uint64Data([UInt64(frameIdBytes.count)]) + frameIdBytes
    data += Data([0x01, 0x02, 0x03, 0x04]) // garbage trailer

    do {
        _ = try VectorSerializer.decodeVecSegment(from: data)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("length mismatch"))
    } catch {
        #expect(Bool(false))
    }
}

/// decodeVecSegment for a properly formed Metal payload with zero vectors decodes correctly.
@Test
func vectorSerializerMetalDecodesZeroVectorPayload() throws {
    // vectorCount=0, dimension=2 → vector bytes = 0, frameId bytes = 0.
    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.cosine.rawValue,
        dimension: 2,
        vectorCount: 0,
        payloadLength: 0
    )
    // frameIdLength = 0, no frameId data.
    let data = header + uint64Data([0])

    let decoded = try VectorSerializer.decodeVecSegment(from: data)
    guard case .metal(let info, let vectors, let frameIds) = decoded else {
        Issue.record("Expected .metal payload")
        return
    }
    #expect(info.dimension == 2)
    #expect(info.vectorCount == 0)
    #expect(vectors.isEmpty)
    #expect(frameIds.isEmpty)
}

/// decodeVecSegment for a Metal payload with multiple vectors decodes all correctly.
@Test
func vectorSerializerMetalDecodesMultipleVectors() throws {
    let dims: UInt32 = 3
    let vecs: [Float] = [1.0, 0.0, 0.0,  // frameId 10
                          0.0, 1.0, 0.0,  // frameId 20
                          0.0, 0.0, 1.0]  // frameId 30
    let fids: [UInt64] = [10, 20, 30]
    let vectorBytes = floatData(vecs)
    let frameIdBytes = uint64Data(fids)

    let header = vecHeader(
        encoding: VectorSerializer.VecEncoding.metal.rawValue,
        similarity: VecSimilarity.l2.rawValue,
        dimension: dims,
        vectorCount: UInt64(fids.count),
        payloadLength: UInt64(vectorBytes.count)
    )
    let data = header + vectorBytes + uint64Data([UInt64(frameIdBytes.count)]) + frameIdBytes

    let decoded = try VectorSerializer.decodeVecSegment(from: data)
    guard case .metal(let info, let decodedVecs, let decodedFids) = decoded else {
        Issue.record("Expected .metal payload")
        return
    }
    #expect(info.dimension == dims)
    #expect(info.vectorCount == 3)
    #expect(info.similarity == .l2)
    #expect(decodedVecs == vecs)
    #expect(decodedFids == fids)
}

/// VecEncoding raw values match expected bytes for the serialized format.
@Test
func vectorSerializerVecEncodingRawValues() {
    #expect(VectorSerializer.VecEncoding.uSearch.rawValue == 1)
    #expect(VectorSerializer.VecEncoding.metal.rawValue == 2)
}

/// SegmentInfo Equatable conformance works correctly.
@Test
func vectorSerializerSegmentInfoEquatable() {
    let a = VectorSerializer.SegmentInfo(similarity: .cosine, dimension: 4, vectorCount: 10, payloadLength: 40)
    let b = VectorSerializer.SegmentInfo(similarity: .cosine, dimension: 4, vectorCount: 10, payloadLength: 40)
    let c = VectorSerializer.SegmentInfo(similarity: .dot, dimension: 4, vectorCount: 10, payloadLength: 40)
    #expect(a == b)
    #expect(a != c)
}

/// decodeVecSegment rejects data that is smaller than the minimum header size.
@Test
func vectorSerializerDecodeVecSegmentRejectsTooSmallData() {
    let tiny = Data([0x01, 0x02])
    do {
        _ = try VectorSerializer.decodeVecSegment(from: tiny)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("too small"))
    } catch {
        #expect(Bool(false))
    }
}

/// USearch round-trip via VectorSerializer preserves vector count and similarity.
@Test
func vectorSerializerUSearchRoundTripPreservesMetadata() async throws {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 100, vector: [1.0, 0.0])
    try await engine.add(frameId: 200, vector: [0.0, 1.0])

    let blob = try await engine.serialize()
    let encoding = try VectorSerializer.detectEncoding(from: blob)
    #expect(encoding == .uSearch)

    let (info, _) = try VectorSerializer.decodeUSearchPayload(from: blob)
    #expect(info.dimension == 2)
    #expect(info.vectorCount == 2)
    #expect(info.similarity == .cosine)
}
