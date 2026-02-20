import Foundation
import Testing
import WaxCore

@Test func putWithCompressionStoresCompressedButReturnsCanonicalOnRead() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let original = Data(repeating: 0xAA, count: 10_000)
    #if os(Linux)
    let compression: CanonicalEncoding = .deflate
    #else
    let compression: CanonicalEncoding = .lzfse
    #endif

    let frameId = try await wax.put(original, compression: compression)
    try await wax.commit()

    let meta = try await wax.frameMeta(frameId: frameId)
    #expect(meta.canonicalEncoding == compression)
    #expect(meta.canonicalLength == UInt64(original.count))

    let stored = try await wax.frameStoredContent(frameId: frameId)
    #expect(stored.count < original.count)

    let roundtripped = try await wax.frameContent(frameId: frameId)
    #expect(roundtripped == original)

    let preview = try await wax.framePreview(frameId: frameId, maxBytes: 16)
    #expect(preview == Data(original.prefix(16)))

    try await wax.close()
}
