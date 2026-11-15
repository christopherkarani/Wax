import Foundation
import Testing
@testable import Wax
import WaxCore

/// Parsing the encoding takes most of a second of CPU in a debug build. The tokenizer
/// tests share one parse, run off the cooperative pool, instead of each holding a pool
/// thread for it while the parallel suite starts.
enum SharedCl100kTokenizer {
    private static let load = Task {
        try await BlockingWork.run { try NativeBpeTokenizer(encoding: .cl100kBase) }
    }

    static func get() async throws -> NativeBpeTokenizer {
        try await load.value
    }
}

@Test func nativeTokenizerEncodesAndDecodes() async throws {
    let native = try await SharedCl100kTokenizer.get()

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

@Test func nativeTokenizerEmptyInput() async throws {
    let native = try await SharedCl100kTokenizer.get()
    let tokens = native.encode("")
    #expect(tokens.isEmpty)
    let decoded = native.decode([])
    #expect(decoded.isEmpty)
}
