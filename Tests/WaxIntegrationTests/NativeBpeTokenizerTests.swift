#if canImport(XCTest)
import XCTest
import SwiftTiktoken
@testable import Wax

final class NativeBpeTokenizerTests: XCTestCase {
    func testNativeEncodingMatchesTiktokenSamples() async throws {
        let native = try NativeBpeTokenizer(encoding: .cl100kBase)
        EncodingLoader.customCacheDirectory = NativeBpeTokenizer.bundledEncodingDirectoryURL()
        let tiktoken = try await EncodingLoader.loadEncoder(named: "cl100k_base")

        let samples = [
            "Hello, world!",
            "Swift 6.2 concurrency",
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
            let nativeTokens = native.encode(sample)
            let tiktokenTokens = tiktoken.encode(text: sample, allowedSpecial: [])
            XCTAssertEqual(nativeTokens, tiktokenTokens, "Mismatch for sample: \(sample)")
        }
    }

    func testNativeDecodingMatchesTiktokenSamples() async throws {
        let native = try NativeBpeTokenizer(encoding: .cl100kBase)
        EncodingLoader.customCacheDirectory = NativeBpeTokenizer.bundledEncodingDirectoryURL()
        let tiktoken = try await EncodingLoader.loadEncoder(named: "cl100k_base")

        let samples = [
            "Wax provides deterministic token counts.",
            "Streaming responses should decode correctly.",
            "Multi-byte: naïve façade déjà vu.",
            "Whitespace    with   gaps",
            "JSON: {\"key\": [1,2,3]}"
        ]

        for sample in samples {
            let tiktokenTokens = tiktoken.encode(text: sample, allowedSpecial: [])
            let nativeDecoded = native.decode(tiktokenTokens)
            let tiktokenDecoded = (try? tiktoken.decode(tokens: tiktokenTokens)) ?? ""
            XCTAssertEqual(nativeDecoded, tiktokenDecoded, "Decode mismatch for sample: \(sample)")
        }
    }
}
#endif
