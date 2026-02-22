import Foundation
import Testing
@testable import WaxCore

@Test func putEmbeddingRoundtrip() throws {
    let original = PutEmbedding(frameId: 42, dimension: 4, vector: [1.0, -2.5, 3.14159, 0.0])
    let encoded = try WALEntryCodec.encode(.putEmbedding(original))
    let decoded = try WALEntryCodec.decode(encoded, offset: 0)
    #expect(decoded == .putEmbedding(original))
}

@Test func putEmbeddingByteLevelLayout() throws {
    let embedding = PutEmbedding(frameId: 1, dimension: 2, vector: [1.0, -2.0])
    let encoded = try WALEntryCodec.encode(.putEmbedding(embedding))

    // OpCode 0x04
    #expect(encoded[0] == 0x04)

    // frameId: UInt64(1) little-endian
    #expect(encoded[1..<9] == Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))

    // dimension: UInt32(2) little-endian
    #expect(encoded[9..<13] == Data([0x02, 0x00, 0x00, 0x00]))

    // 1.0f IEEE 754 LE: 0x3F800000
    #expect(encoded[13..<17] == Data([0x00, 0x00, 0x80, 0x3F]))

    // -2.0f IEEE 754 LE: 0xC0000000
    #expect(encoded[17..<21] == Data([0x00, 0x00, 0x00, 0xC0]))

    // Total: opcode(1) + frameId(8) + dimension(4) + floats(8) = 21
    #expect(encoded.count == 21)
}

@Test func putEmbeddingLargeDimension() throws {
    let dim = 384
    let vector = (0..<dim).map { Float($0) * 0.01 }
    let original = PutEmbedding(frameId: 100, dimension: UInt32(dim), vector: vector)
    let encoded = try WALEntryCodec.encode(.putEmbedding(original))
    let decoded = try WALEntryCodec.decode(encoded, offset: 0)
    #expect(decoded == .putEmbedding(original))
}

@Test func putEmbeddingSingleDimension() throws {
    let original = PutEmbedding(frameId: 7, dimension: 1, vector: [42.0])
    let encoded = try WALEntryCodec.encode(.putEmbedding(original))
    let decoded = try WALEntryCodec.decode(encoded, offset: 0)
    #expect(decoded == .putEmbedding(original))
}

@Test func putEmbeddingSpecialFloats() throws {
    let vector: [Float] = [.infinity, -.infinity, .nan, 0.0, -0.0]
    let original = PutEmbedding(frameId: 99, dimension: 5, vector: vector)
    let encoded = try WALEntryCodec.encode(.putEmbedding(original))
    let decoded = try WALEntryCodec.decode(encoded, offset: 0)

    guard case .putEmbedding(let result) = decoded else {
        #expect(Bool(false), "Expected putEmbedding")
        return
    }

    #expect(result.frameId == 99)
    #expect(result.dimension == 5)
    #expect(result.vector.count == 5)

    // Compare bitPatterns since NaN != NaN
    for (a, b) in zip(original.vector, result.vector) {
        #expect(a.bitPattern == b.bitPattern)
    }
}

@Test func supersedeFrameRoundtrip() throws {
    let original = SupersedeFrame(supersededId: 10, supersedingId: 20)
    let encoded = try WALEntryCodec.encode(.supersedeFrame(original))
    let decoded = try WALEntryCodec.decode(encoded, offset: 0)
    #expect(decoded == .supersedeFrame(original))
}

@Test func putFrameEncodingRejectsOversizedPayloadLengths() throws {
    let checksum = Data(repeating: 0xAB, count: 32)
    let oversizedPayload = PutFrame(
        frameId: 1,
        timestampMs: 1,
        options: FrameMetaSubset(),
        payloadOffset: 0,
        payloadLength: Constants.maxFramePayloadBytes + 1,
        canonicalEncoding: .plain,
        canonicalLength: 1,
        canonicalChecksum: checksum,
        storedChecksum: checksum
    )

    do {
        _ = try WALEntryCodec.encode(.putFrame(oversizedPayload))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("payload_length"))
    }
}

@Test func putFrameDecodingRejectsOversizedCanonicalLength() throws {
    var encoder = BinaryEncoder()
    encoder.encode(WALEntryCodec.OpCode.putFrame.rawValue)
    encoder.encode(UInt64(1))
    encoder.encode(Int64(1))
    var options = FrameMetaSubset()
    try options.encode(to: &encoder)
    encoder.encode(UInt64(0))
    encoder.encode(UInt64(1))
    encoder.encode(CanonicalEncoding.lzfse.rawValue)
    encoder.encode(Constants.maxFramePayloadBytes + 1)
    encoder.encodeFixedBytes(Data(repeating: 0x01, count: 32))
    encoder.encodeFixedBytes(Data(repeating: 0x02, count: 32))

    do {
        _ = try WALEntryCodec.decode(encoder.data, offset: 0)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .walCorruption(_, let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("canonical_length"))
    }
}

@Test func putFrameEncodingRejectsOversizedCanonicalLength() throws {
    let checksum = Data(repeating: 0xCD, count: 32)
    let oversized = PutFrame(
        frameId: 1,
        timestampMs: 1,
        options: FrameMetaSubset(),
        payloadOffset: 0,
        payloadLength: 1,
        canonicalEncoding: .plain,
        canonicalLength: Constants.maxFramePayloadBytes + 1,
        canonicalChecksum: checksum,
        storedChecksum: checksum
    )

    do {
        _ = try WALEntryCodec.encode(.putFrame(oversized))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("canonical_length"))
    }
}

@Test func putFrameEncodingRejectsInvalidChecksumLengths() throws {
    let validChecksum = Data(repeating: 0xAB, count: 32)

    do {
        _ = try WALEntryCodec.encode(
            .putFrame(
                PutFrame(
                    frameId: 1,
                    timestampMs: 1,
                    options: FrameMetaSubset(),
                    payloadOffset: 0,
                    payloadLength: 1,
                    canonicalEncoding: .plain,
                    canonicalLength: 1,
                    canonicalChecksum: Data(repeating: 0x01, count: 31),
                    storedChecksum: validChecksum
                )
            )
        )
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("canonical_checksum"))
    }

    do {
        _ = try WALEntryCodec.encode(
            .putFrame(
                PutFrame(
                    frameId: 1,
                    timestampMs: 1,
                    options: FrameMetaSubset(),
                    payloadOffset: 0,
                    payloadLength: 1,
                    canonicalEncoding: .plain,
                    canonicalLength: 1,
                    canonicalChecksum: validChecksum,
                    storedChecksum: Data(repeating: 0x02, count: 31)
                )
            )
        )
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("stored_checksum"))
    }
}

@Test func putEmbeddingEncodingRejectsDimensionMismatchAndLimitOverflow() throws {
    do {
        _ = try WALEntryCodec.encode(
            .putEmbedding(PutEmbedding(frameId: 1, dimension: 2, vector: [1]))
        )
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("dimension mismatch"))
    }

    do {
        let tooMany = [Float](repeating: 0, count: Constants.maxEmbeddingDimensions + 1)
        _ = try WALEntryCodec.encode(
            .putEmbedding(
                PutEmbedding(
                    frameId: 1,
                    dimension: UInt32(tooMany.count),
                    vector: tooMany
                )
            )
        )
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("exceeds limit"))
    }
}

@Test func decodeRejectsUnknownOpcodeAsWalCorruption() throws {
    do {
        _ = try WALEntryCodec.decode(Data([0xFF]), offset: 77)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .walCorruption(let offset, let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(offset == 77)
        #expect(reason.contains("unknown opcode"))
    }
}

@Test func decodeRejectsInvalidCanonicalEncodingAsWalCorruption() throws {
    var encoder = BinaryEncoder()
    encoder.encode(WALEntryCodec.OpCode.putFrame.rawValue)
    encoder.encode(UInt64(9))
    encoder.encode(Int64(10))
    var options = FrameMetaSubset()
    try options.encode(to: &encoder)
    encoder.encode(UInt64(0))
    encoder.encode(UInt64(1))
    encoder.encode(UInt8(255))
    encoder.encode(UInt64(1))
    encoder.encodeFixedBytes(Data(repeating: 0xAA, count: 32))
    encoder.encodeFixedBytes(Data(repeating: 0xBB, count: 32))

    do {
        _ = try WALEntryCodec.decode(encoder.data, offset: 5)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .walCorruption(let offset, let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(offset == 5)
        #expect(reason.contains("invalid canonical_encoding"))
    }
}

@Test func decodeRejectsTooLargeEmbeddingDimensionAsWalCorruption() throws {
    var encoder = BinaryEncoder()
    encoder.encode(WALEntryCodec.OpCode.putEmbedding.rawValue)
    encoder.encode(UInt64(1))
    encoder.encode(UInt32(Constants.maxEmbeddingDimensions + 1))

    do {
        _ = try WALEntryCodec.decode(encoder.data, offset: 11)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .walCorruption(let offset, let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(offset == 11)
        #expect(reason.contains("embedding dimension exceeds limit"))
    }
}

@Test func decodeWrapsTruncatedPayloadAsWalCorruption() throws {
    let truncated = Data([WALEntryCodec.OpCode.deleteFrame.rawValue])
    do {
        _ = try WALEntryCodec.decode(truncated, offset: 123)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .walCorruption(let offset, _) = error else {
            #expect(Bool(false))
            return
        }
        #expect(offset == 123)
    }
}
