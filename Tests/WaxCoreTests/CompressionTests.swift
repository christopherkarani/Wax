import Foundation
import Testing
import WaxCore

private func repeatedData(_ seed: Data, count: Int) -> Data {
    var out = Data()
    out.reserveCapacity(seed.count * max(0, count))
    for _ in 0..<max(0, count) { out.append(seed) }
    return out
}

@Test func lzfseRoundtrip() throws {
    let original = Data(repeating: 0xAA, count: 10_000)
    #if os(Linux)
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.compress(original, algorithm: .lzfse)
    }
    #else
    let compressed = try PayloadCompressor.compress(original, algorithm: .lzfse)
    let decompressed = try PayloadCompressor.decompress(compressed, algorithm: .lzfse, uncompressedLength: original.count)
    #expect(decompressed == original)
    #expect(compressed.count < original.count)
    #endif
}

@Test func lz4Roundtrip() throws {
    let original = repeatedData(Data("Hello, World! ".utf8), count: 1000)
    #if os(Linux)
    #expect(throws: WaxError.self) {
        _ = try PayloadCompressor.compress(original, algorithm: .lz4)
    }
    #else
    let compressed = try PayloadCompressor.compress(original, algorithm: .lz4)
    let decompressed = try PayloadCompressor.decompress(compressed, algorithm: .lz4, uncompressedLength: original.count)
    #expect(decompressed == original)
    #endif
}

@Test func deflateRoundtrip() throws {
    let original = repeatedData(Data((0..<256).map { UInt8($0) }), count: 100)
    let compressed = try PayloadCompressor.compress(original, algorithm: .deflate)
    let decompressed = try PayloadCompressor.decompress(compressed, algorithm: .deflate, uncompressedLength: original.count)
    #expect(decompressed == original)
}

@Test func noCompressionRoundtrip() throws {
    let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let compressed = try PayloadCompressor.compress(original, algorithm: .none)
    let decompressed = try PayloadCompressor.decompress(compressed, algorithm: .none, uncompressedLength: original.count)
    #expect(compressed == original)
    #expect(decompressed == original)
}

@Test func smallDataNoHugeExpansion() throws {
    let original = Data([1, 2, 3, 4, 5])
    #if os(Linux)
    let compressed = try PayloadCompressor.compress(original, algorithm: .deflate)
    #else
    let compressed = try PayloadCompressor.compress(original, algorithm: .lzfse)
    #endif
    #expect(compressed.count < original.count + 128)
}
