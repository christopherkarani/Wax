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
