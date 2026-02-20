import Foundation
import Testing
@testable import WaxCore

private func dataFromHex(_ hex: String) -> Data {
    precondition(hex.count.isMultiple(of: 2), "hex length must be even")
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        let byteString = hex[index..<next]
        let value = UInt8(byteString, radix: 16)!
        bytes.append(value)
        index = next
    }
    return Data(bytes)
}

private let canonicalFixture = Data(repeating: 0x41, count: 4096)
private let lzfseFixture = dataFromHex("6276783200100000040000000003007000000000000c0050830000002490000ce7d75c030000005c03000000c04ff0937c0f00000000000000000000000000000000000000000000000000000000000000c0a30f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003456ff3f62767824")
private let lz4Fixture = dataFromHex("6276343100100000910000001f410100ffffffffffffffffffffffffffffff80f06c41414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414162763424")
private let deflateFixture = dataFromHex("edc1010d000000c2a06cef5fca1e0e28000000e0dd00")

@Test func deflateFixtureDecodesOnAllPlatforms() throws {
    let decoded = try PayloadCompressor.decompress(
        deflateFixture,
        algorithm: .deflate,
        uncompressedLength: canonicalFixture.count
    )
    #expect(decoded == canonicalFixture)
}

@Test func lzfseFixtureBehaviorMatchesPlatformSupport() throws {
    #if os(Linux)
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.decompress(
            lzfseFixture,
            algorithm: .lzfse,
            uncompressedLength: canonicalFixture.count
        )
    }
    #else
    let decoded = try PayloadCompressor.decompress(
        lzfseFixture,
        algorithm: .lzfse,
        uncompressedLength: canonicalFixture.count
    )
    #expect(decoded == canonicalFixture)
    #endif
}

@Test func lz4FixtureBehaviorMatchesPlatformSupport() throws {
    #if os(Linux)
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.decompress(
            lz4Fixture,
            algorithm: .lz4,
            uncompressedLength: canonicalFixture.count
        )
    }
    #else
    let decoded = try PayloadCompressor.decompress(
        lz4Fixture,
        algorithm: .lz4,
        uncompressedLength: canonicalFixture.count
    )
    #expect(decoded == canonicalFixture)
    #endif
}
