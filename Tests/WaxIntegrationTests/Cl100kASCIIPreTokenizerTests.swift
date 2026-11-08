import Foundation
import Testing
@testable import Wax

/// The ASCII scanner must split text exactly where the cl100k_base regex does.
@Suite struct Cl100kASCIIPreTokenizerTests {
    private static let regex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: NativeBpeTokenizer.cl100kBasePattern)
        } catch {
            preconditionFailure("Invalid cl100k_base regex: \(error)")
        }
    }()

    /// Piece byte ranges from the regex. ASCII text has one UTF-16 unit per byte.
    private static func regexPieces(_ text: String) -> [Range<Int>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            $0.range.location..<($0.range.location + $0.range.length)
        }
    }

    private static func scannerPieces(_ text: String) -> [Range<Int>] {
        Array(text.utf8).withUnsafeBufferPointer { Cl100kASCIIPreTokenizer.pieceRanges($0) }
    }

    private static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    @Test func everyFourCharacterCombinationOfTheRegexClassesSplitsLikeTheRegex() {
        // Letters (including contraction letters in both cases), digits, every ASCII
        // whitespace ICU's \s matches, an apostrophe, punctuation and a control byte.
        let alphabet: [UInt8] = Array("aAsSrReElLx1 '.".utf8) + [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x00]
        var mismatches: [String] = []
        for a in alphabet {
            for b in alphabet {
                for c in alphabet {
                    for d in alphabet {
                        let text = Self.string([a, b, c, d])
                        if Self.scannerPieces(text) != Self.regexPieces(text) {
                            mismatches.append(text.debugDescription)
                        }
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(10))")
    }

    @Test func randomASCIITextSplitsLikeTheRegex() {
        var rng = SplitMix64(seed: 0x5EED_C1_00)
        // Bias towards characters with distinct regex roles so long runs and mixes occur.
        let common: [UInt8] = Array("aeiou st'rvmldSTRVMLD0123456789  \n\r\t.,-!?".utf8)
        var mismatches: [String] = []
        for _ in 0..<20_000 {
            let length = Int(rng.next() % 64)
            let bytes: [UInt8] = (0..<length).map { _ in
                rng.next() % 3 == 0 ? UInt8(rng.next() % 128) : common[Int(rng.next() % UInt64(common.count))]
            }
            let text = Self.string(bytes)
            if Self.scannerPieces(text) != Self.regexPieces(text) {
                mismatches.append(text.debugDescription)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(10))")
    }

    @Test func asciiAndRegexPathsProduceTheSameTokens() throws {
        let native = try NativeBpeTokenizer(encoding: .cl100kBase)
        let samples = [
            "Hello, world! It's 2026; they'll say we've won 1234567 times.",
            "Tabs\tand\r\nWindows newlines\n\n   indented\u{0B}vertical\u{0C}feed  ",
            "Symbols: [@#$%^&*()] --> ok?!\n\r\n",
        ]
        // A non-ASCII prefix forces the regex path for the whole text. It ends in a newline
        // run, so its pieces stay separate from samples that start with a letter.
        let prefix = "é\n\n"
        for sample in samples {
            let regexTokens = native.encode(prefix + sample).dropFirst(native.encode(prefix).count)
            #expect(native.encode(sample) == Array(regexTokens), "token mismatch for \(sample.debugDescription)")
            #expect(native.decode(native.encode(sample)) == sample)
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
