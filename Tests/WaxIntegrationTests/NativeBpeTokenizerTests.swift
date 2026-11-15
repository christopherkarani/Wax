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

/// Tokens recorded from the regex tokenizer before the fast paths, so lookups and
/// pre-tokenization stay exact: pieces of 7 and 8 bytes, contractions (including `ſ`,
/// which `(?i)` matches as `s`), non-ASCII letters, digits and whitespace, emoji
/// sequences, and private-use and Unicode 15 scalars, which take the regex.
@Test func nativeTokenizerMatchesRecordedTokens() throws {
    let native = try NativeBpeTokenizer(encoding: .cl100kBase)
    let cases: [(text: String, tokens: [UInt32])] = [
        ("Hello, world!", [9906, 11, 1917, 0]),
        ("hello world", [15339, 1917]),
        (" example exampled examples", [3187, 3187, 67, 10507]),
        ("abcdefg abcdefgh a ab abc", [42302, 70, 40122, 755, 876, 264, 671, 40122]),
        (
            "It's they'll we've I'm you'd 'RE 'Ll x'\u{17F}",
            [2181, 596, 814, 3358, 584, 3077, 358, 2846, 499, 4265, 364, 793, 364, 43, 75, 865, 6, 129, 123]
        ),
        ("Numbers: 123 4567 890 1234567", [28336, 25, 220, 4513, 220, 10961, 22, 220, 21381, 220, 4513, 10961, 22]),
        ("Tabs\tand\r\nWindows newlines\n\n   indented", [38085, 53577, 319, 13466, 502, 8128, 271, 256, 1280, 16243]),
        (
            "Emoji 🤖🚀 and accents café, naïve résumé",
            [93831, 11410, 97, 244, 9468, 248, 222, 323, 59570, 53050, 11, 95980, 588, 9517, 1264, 978]
        ),
        (
            "Mixed العربية English 日本語 한국어",
            [87533, 17607, 24102, 11318, 22071, 74541, 6498, 76502, 22656, 45918, 252, 62398, 89059, 255, 32179]
        ),
        (
            "Non-breaking\u{A0}space and ideographic\u{3000}space\u{2028}line",
            [8284, 55407, 4194, 8920, 323, 2679, 12968, 23249, 8920, 378, 101, 1074]
        ),
        (
            "Family 👨‍👩‍👧 flag 🇰🇪 keycap 1️⃣",
            [15547, 62904, 101, 378, 235, 9468, 239, 102, 378, 235, 9468, 239, 100, 5292, 11410, 229, 108, 9468, 229, 103, 1401, 11600, 220, 16, 31643, 158, 225, 96]
        ),
        (
            "Superscript ² roman Ⅻ fraction ½ arabic ٣٤٥٦",
            [10254, 388, 1250, 220, 30556, 48876, 220, 71567, 104, 19983, 220, 27154, 52412, 292, 220, 149, 96, 149, 97, 149, 98, 149, 99]
        ),
        (
            "Private \u{E000} use \u{F882} and new \u{1FAE8} scalars",
            [17205, 220, 170, 222, 222, 1005, 33595, 95, 224, 323, 502, 11410, 104, 101, 24964, 1590]
        ),
    ]
    for (text, tokens) in cases {
        #expect(native.encode(text) == tokens, "tokens for \(text.debugDescription)")
    }
}
