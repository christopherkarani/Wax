import Foundation
import Testing
@testable import Wax

@Test func nativeTokenizerEncodesAndDecodes() throws {
    let native = try NativeBpeTokenizer(encoding: .cl100kBase)

    let samples = [
        "Hello, world!",
        "Swift 6.1 concurrency",
        "The quick brown fox jumps over 13 lazy dogs.",
        "Emoji 🤖🚀 and accents café",
        "Line1\nLine2\nLine3",
        "Tabs\tand\r\nWindows newlines",
        "Numbers: 123 4567 890",
        "Symbols: [@#$%^&*()]",
        "Mixed العربية English 日本語",
        "Longer paragraph with punctuation—dash, ellipsis… and quotes."
    ]

    for sample in samples {
        let tokens = native.encode(sample)
        #expect(!tokens.isEmpty, "Expected non-empty tokens for sample: \(sample)")
        let decoded = native.decode(tokens)
        #expect(decoded == sample, "Round-trip mismatch for sample: \(sample)")
    }
}

@Test func nativeTokenizerEmptyInput() throws {
    let native = try NativeBpeTokenizer(encoding: .cl100kBase)
    let tokens = native.encode("")
    #expect(tokens.isEmpty)
    let decoded = native.decode([])
    #expect(decoded.isEmpty)
}
