import Foundation
import Testing
@testable import WaxCore

@Test(
    "CompressionKind ↔ CanonicalEncoding round-trip for every case",
    arguments: [
        (CompressionKind.none, CanonicalEncoding.plain),
        (.lzfse, .lzfse),
        (.lz4, .lz4),
        (.deflate, .deflate),
    ] as [(CompressionKind, CanonicalEncoding)]
)
func compressionKindCanonicalEncodingRoundTrip(
    kind: CompressionKind,
    encoding: CanonicalEncoding
) {
    #expect(kind.canonicalEncoding == encoding)
    #expect(CompressionKind(canonicalEncoding: encoding) == kind)
}
