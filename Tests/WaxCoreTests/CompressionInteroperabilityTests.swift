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
/// Legacy Apple `COMPRESSION_LZ4` output: `bv41` block frame + `bv4$` end marker.
private let lz4Fixture = dataFromHex("6276343100100000910000001f410100ffffffffffffffffffffffffffffff80f06c41414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414162763424")
private let deflateFixture = dataFromHex("edc1010d000000c2a06cef5fca1e0e28000000e0dd00")
/// liblz4 `LZ4_compress_default` raw block for `canonicalFixture` (what Linux writes).
private let lz4RawBlockFixture = dataFromHex("1f410100fffffffffffffffffffffffffffffff6504141414141")
/// Legacy Apple `COMPRESSION_LZ4` frame spanning three 64 KiB `bv41` blocks whose
/// matches reach back into the previous block.
private let lz4MultiBlockInput = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
private let lz4MultiBlockFixture = dataFromHex(
    "62763431000001007a020000ffec000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d" +
    "2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60616263646566676869" +
    "6a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5" +
    "a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1" +
    "e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafb00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff78f06a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9" +
    "aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5" +
    "e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fa000102030405060708090a0b0c0d0e0f1011121314151617186276343100000100820100000fe7" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffff71f06db1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8" +
    "d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fa000102030405060708090a0b0c0d0e0f10111213141516171819" +
    "1a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303162763431f0490000c80000000ffb00ffffffffffffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffadf06a2021222324" +
    "25262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60" +
    "6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f90919293949596979862763424"
)
/// Legacy Apple `COMPRESSION_LZ4` frame holding one uncompressed `bv4-` block.
private let lz4StoredBlockInput: Data = {
    var state: UInt32 = 0x9E37_79B9
    return Data((0..<300).map { _ -> UInt8 in
        state = state &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: state >> 24)
    })
}()
private let lz4StoredBlockFixture = dataFromHex(
    "6276342d2c01000042e93f60d5169647e0bc132e87fcee8af6fed90299d1b0cf4152fd51fc1a43ab86f1156287624e491d4a053c5c9f0869bcb1f932" +
    "a7ab5bec9e1f2af4a7ceccf0f408723006543c7da834b6d08a377bc36db41db307d89ee225e3100bb1c6334b94731b3cb19741ab5d90895213d21168" +
    "5a11e20700e5d1ab3cb72d54473000007f7d0999381aaf80abfb9350ce3f8c8fe7d41c532ea3c327dc38afab69feaeb7e57569fea0114e8b97939f7a" +
    "65139fd08e0dd3607f28b51792897c15ece5a97909ac9dc842f15941b9fd2aa656a6f428dcd1409e36cb5d21814e29b8776156b8407a37f6cc777ffb" +
    "3a6066caf21226fa7038d31deb2be3d15eb105de87af0945f63a032c3fa1e4f4dd673906613ac609ff5f2e938928e593725f0ef76cd10f59a949fcb1" +
    "f0b2204cf3413d9862763424"
)

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

@Test func legacyAppleFramedLZ4FixtureDecodesOnAllPlatforms() throws {
    let decoded = try PayloadCompressor.decompress(
        lz4Fixture,
        algorithm: .lz4,
        uncompressedLength: canonicalFixture.count
    )
    #expect(decoded == canonicalFixture)
}

@Test func legacyAppleFramedMultiBlockLZ4FixtureDecodesOnAllPlatforms() throws {
    let decoded = try PayloadCompressor.decompress(
        lz4MultiBlockFixture,
        algorithm: .lz4,
        uncompressedLength: lz4MultiBlockInput.count
    )
    #expect(decoded == lz4MultiBlockInput)
}

@Test func legacyAppleFramedStoredBlockLZ4FixtureDecodesOnAllPlatforms() throws {
    let decoded = try PayloadCompressor.decompress(
        lz4StoredBlockFixture,
        algorithm: .lz4,
        uncompressedLength: lz4StoredBlockInput.count
    )
    #expect(decoded == lz4StoredBlockInput)
}

@Test func rawBlockLZ4FixtureDecodesOnAllPlatforms() throws {
    let decoded = try PayloadCompressor.decompress(
        lz4RawBlockFixture,
        algorithm: .lz4,
        uncompressedLength: canonicalFixture.count
    )
    #expect(decoded == canonicalFixture)
}

@Test func lz4CompressionWritesRawBlockFormat() throws {
    let compressed = try PayloadCompressor.compress(lz4MultiBlockInput, algorithm: .lz4)
    // Raw LZ4 blocks carry no `bv4` frame magic, so liblz4 on Linux decodes them directly.
    #expect(!compressed.starts(with: Data("bv4".utf8)))
    let decoded = try PayloadCompressor.decompress(
        compressed,
        algorithm: .lz4,
        uncompressedLength: lz4MultiBlockInput.count
    )
    #expect(decoded == lz4MultiBlockInput)
}

@Test func lz4DecompressRejectsCorruptFrame() {
    var corrupt = lz4MultiBlockFixture
    corrupt.removeLast(40)
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.decompress(
            corrupt,
            algorithm: .lz4,
            uncompressedLength: lz4MultiBlockInput.count
        )
    }
}
