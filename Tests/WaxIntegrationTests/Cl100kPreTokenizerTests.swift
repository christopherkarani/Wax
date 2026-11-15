import Foundation
import Testing
@testable import Wax

/// The scanner must split text exactly where the cl100k_base regex does.
@Suite struct Cl100kPreTokenizerTests {
    private static let regex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: NativeBpeTokenizer.cl100kBasePattern)
        } catch {
            preconditionFailure("Invalid cl100k_base regex: \(error)")
        }
    }()

    /// Piece UTF-8 byte ranges from the regex.
    private static func regexPieces(_ text: String) -> [Range<Int>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
            return start..<(start + text[range].utf8.count)
        }
    }

    private static func scannerPieces(_ text: String) -> [Range<Int>]? {
        Array(text.utf8).withUnsafeBufferPointer { Cl100kPreTokenizer.pieceRanges($0) }
    }

    private static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
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

    /// Every scalar the scanner accepts, placed where its class decides the split: inside
    /// and after letters, after an apostrophe, between digits, and in whitespace runs.
    @Test func everyAcceptedScalarSplitsLikeTheRegex() {
        var accepted: [Unicode.Scalar] = []
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if Self.scannerPieces(String(Character(scalar))) != nil { accepted.append(scalar) }
        }
        #expect(accepted.count > 100_000, "accepted \(accepted.count) scalars")

        var mismatches: [String] = []
        let chunkSize = 64
        for chunkStart in stride(from: 0, to: accepted.count, by: chunkSize) {
            var scalars: [Unicode.Scalar] = []
            for scalar in accepted[chunkStart..<min(chunkStart + chunkSize, accepted.count)] {
                let contexts: [Unicode.Scalar] = [
                    "a", scalar, "b", "'", scalar, "e", " ", "1", scalar, "2", " ", " ", scalar, "\n", scalar, " ",
                ]
                scalars += contexts
            }
            let text = Self.string(scalars)
            if Self.scannerPieces(text) != Self.regexPieces(text) {
                mismatches.append("chunk from U+\(String(accepted[chunkStart].value, radix: 16, uppercase: true))")
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(10))")
    }

    @Test func randomUnicodeTextSplitsLikeTheRegex() {
        var rng = SplitMix64(seed: 0xC1_00_0FF)
        let trickyText: String =
            "aZ09 '\r\n\t\u{0B}\u{0C}\u{85}\u{A0}\u{1680}\u{2000}\u{200B}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
                + "sStTlLeEmMdDrRvV\u{17F}\u{212A}é\u{301}\u{308}ß東京🚀😀\u{200D}\u{FE0F}٣²Ⅻ½-_.,!?\"()<>@#%&*+=/|~;:"
        let tricky = Array(trickyText.unicodeScalars)
        var mismatches: [String] = []
        for _ in 0..<20_000 {
            let length = 1 + Int(rng.next() % 24)
            let scalars = (0..<length).map { _ in tricky[Int(rng.next() % UInt64(tricky.count))] }
            let text = Self.string(scalars)
            if Self.scannerPieces(text) != Self.regexPieces(text) {
                mismatches.append(text.debugDescription)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(10))")
    }

    @Test func longSIsAContractionLetter() {
        #expect(Self.scannerPieces("x'\u{17F}t") == [0..<1, 1..<4, 4..<5])
        #expect(Self.scannerPieces("x'\u{17F}t") == Self.regexPieces("x'\u{17F}t"))
    }

    /// Apple's ICU gives U+F882 letter properties, U+1FAE8 is from Unicode 15, U+0378 is
    /// unassigned, and invalid UTF-8 has no scalars.
    @Test func textICUMayClassDifferentlyIsLeftToTheRegex() {
        for text in ["a\u{E000}b", "a\u{F882}b", "a \u{1FAE8}", "x\u{378}", "\u{10FFFD}"] {
            #expect(Self.scannerPieces(text) == nil, "\(text.debugDescription)")
        }
        let invalid: [UInt8] = [0x61, 0xFF, 0x62]
        #expect(invalid.withUnsafeBufferPointer { Cl100kPreTokenizer.pieceRanges($0) } == nil)
    }

    @Test func scannerAndRegexPathsProduceTheSameTokens() throws {
        let native = try NativeBpeTokenizer(encoding: .cl100kBase)
        let samples = [
            "Hello, world! It's 2026; they'll say we've won 1234567 times.",
            "Tabs\tand\r\nWindows newlines\n\n   indented\u{0B}vertical\u{0C}feed  ",
            "Symbols: [@#$%^&*()] --> ok?!\n\r\n",
            "Café naïve 東京 🚀 \u{A0}nbsp ٣٤٥ x'\u{17F} ü\u{308}",
        ]
        // A private-use prefix forces the regex path for the whole text. It ends in a
        // newline run, so its pieces stay separate from samples that start with a letter.
        let prefix = "\u{E000}\n\n"
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
