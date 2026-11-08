import Foundation
import Testing
@testable import WaxCore

@Test func indexManifestsRoundtrip() throws {
    let lex = LexIndexManifest(
        docCount: 10,
        bytesOffset: 1000,
        bytesLength: 2000,
        checksum: Data(repeating: 0xAA, count: 32),
        version: 1
    )
    let vec = VecIndexManifest(
        vectorCount: 42,
        dimension: 384,
        similarity: .cosine,
        runs: [
            VecRunManifest(
                bytesOffset: 3000,
                bytesLength: 4000,
                checksum: Data(repeating: 0xBB, count: 32),
                rowCount: 40,
                tombstoneCount: 0,
                level: 64,
                addedGeneration: 0,
                keysChecksum: nil
            ),
            VecRunManifest(
                bytesOffset: 7000,
                bytesLength: 100,
                checksum: Data(repeating: 0xCC, count: 32),
                rowCount: 2,
                tombstoneCount: 1,
                level: 0,
                addedGeneration: 9,
                keysChecksum: Data(repeating: 0xDD, count: 32)
            ),
        ]
    )

    var manifests = IndexManifests(lex: lex, vec: vec)
    var encoder = BinaryEncoder()
    try manifests.encode(to: &encoder)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try IndexManifests.decode(from: &decoder)
    try decoder.finalize()

    #expect(decoded == manifests)
}

@Test func indexManifestsDecodeRejectsClipTagPresent() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(0)) // lex absent
    encoder.encode(UInt8(0)) // vec absent
    encoder.encode(UInt8(1)) // clip present (unsupported in v1)

    do {
        var decoder = try BinaryDecoder(data: encoder.data)
        _ = try IndexManifests.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func vecIndexManifestRejectsInvalidSimilarity() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(0)) // lex absent
    encoder.encode(UInt8(1)) // vec present

    encoder.encode(UInt64(1)) // vector_count
    encoder.encode(UInt32(384)) // dimension
    encoder.encode(UInt64(1000)) // bytes_offset
    encoder.encode(UInt64(2000)) // bytes_length
    encoder.encodeFixedBytes(Data(repeating: 0xCC, count: 32)) // checksum
    encoder.encode(UInt8(9)) // similarity invalid

    encoder.encode(UInt8(0)) // clip absent

    do {
        var decoder = try BinaryDecoder(data: encoder.data)
        _ = try IndexManifests.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}
