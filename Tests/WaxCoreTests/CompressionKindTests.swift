import Foundation
import Testing
@testable import WaxCore

@Test func compressionKindFromCanonicalEncodingLzfse() {
    let kind = CompressionKind(canonicalEncoding: .lzfse)
    #expect(kind == .lzfse)
}

@Test func compressionKindFromCanonicalEncodingLz4() {
    let kind = CompressionKind(canonicalEncoding: .lz4)
    #expect(kind == .lz4)
}

@Test func compressionKindFromCanonicalEncodingDeflate() {
    let kind = CompressionKind(canonicalEncoding: .deflate)
    #expect(kind == .deflate)
}

@Test func compressionKindFromCanonicalEncodingPlain() {
    let kind = CompressionKind(canonicalEncoding: .plain)
    #expect(kind == .none)
}

@Test func compressionKindToCanonicalEncodingRoundTrip() {
    let cases: [(CompressionKind, CanonicalEncoding)] = [
        (.none, .plain),
        (.lzfse, .lzfse),
        (.lz4, .lz4),
        (.deflate, .deflate),
    ]
    for (kind, expected) in cases {
        #expect(kind.canonicalEncoding == expected)
        #expect(CompressionKind(canonicalEncoding: expected) == kind)
    }
}
