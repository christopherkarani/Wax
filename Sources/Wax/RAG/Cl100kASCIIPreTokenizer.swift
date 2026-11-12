/// Splits ASCII text into the pieces the cl100k_base pre-tokenizer regex matches
/// (``NativeBpeTokenizer/cl100kBasePattern``) without running ICU.
///
/// For ASCII, `\p{L}` is `[A-Za-z]`, `\p{N}` is `[0-9]` and ICU's `\s` is
/// `[\t\n\u{0B}\u{0C}\r ]`. The scanner tries the pattern's alternatives in order and
/// returns the match the regex engine's backtracking would. Every ASCII byte starts some
/// match, so the pieces cover the text. Non-ASCII text must use the regex.
package enum Cl100kASCIIPreTokenizer {
    private static let letter: UInt8 = 1
    private static let digit: UInt8 = 2
    private static let space: UInt8 = 4
    private static let newline: UInt8 = 8

    private static let classes: [UInt8] = (0..<128).map { byte in
        switch byte {
        case 0x41...0x5A, 0x61...0x7A: letter
        case 0x30...0x39: digit
        case 0x0A, 0x0D: space | newline
        case 0x09, 0x0B, 0x0C, 0x20: space
        default: 0
        }
    }

    package static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        bytes.allSatisfy { $0 < 0x80 }
    }

    /// Byte ranges of the pieces, in order. `bytes` must be ASCII.
    package static func pieceRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < bytes.count {
            let end = pieceEnd(bytes, from: start)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private static func pieceEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let count = bytes.count
        func kind(_ index: Int) -> UInt8 { classes[Int(bytes[index])] }
        func lowered(_ index: Int) -> UInt8 { bytes[index] | 0x20 }

        // (?i:'s|'t|'re|'ve|'m|'ll|'d)
        if bytes[start] == UInt8(ascii: "'"), start + 1 < count {
            switch lowered(start + 1) {
            case UInt8(ascii: "s"), UInt8(ascii: "t"), UInt8(ascii: "m"), UInt8(ascii: "d"):
                return start + 2
            case UInt8(ascii: "r"), UInt8(ascii: "v"):
                if start + 2 < count, lowered(start + 2) == UInt8(ascii: "e") { return start + 3 }
            case UInt8(ascii: "l"):
                if start + 2 < count, lowered(start + 2) == UInt8(ascii: "l") { return start + 3 }
            default:
                break
            }
        }

        // [^\r\n\p{L}\p{N}]?\p{L}+
        var letterStart: Int?
        if kind(start) & letter != 0 {
            letterStart = start
        } else if kind(start) & (letter | digit | newline) == 0, start + 1 < count, kind(start + 1) & letter != 0 {
            letterStart = start + 1
        }
        if var end = letterStart {
            while end < count, kind(end) & letter != 0 { end += 1 }
            return end
        }

        // \p{N}{1,3}
        if kind(start) & digit != 0 {
            var end = start + 1
            while end < count, end - start < 3, kind(end) & digit != 0 { end += 1 }
            return end
        }

        // ` ?[^\s\p{L}\p{N}]+[\r\n]*`
        let other = letter | digit | space
        var symbolStart = start
        if bytes[start] == UInt8(ascii: " "), start + 1 < count, kind(start + 1) & other == 0 {
            symbolStart = start + 1
        }
        if kind(symbolStart) & other == 0 {
            var end = symbolStart + 1
            while end < count, kind(end) & other == 0 { end += 1 }
            while end < count, kind(end) & newline != 0 { end += 1 }
            return end
        }

        // Only whitespace is left. `runEnd` ends the whitespace run.
        var runEnd = start
        var lastNewline: Int?
        while runEnd < count, kind(runEnd) & space != 0 {
            if kind(runEnd) & newline != 0 { lastNewline = runEnd }
            runEnd += 1
        }
        // \s*[\r\n]+ ends at the run's last newline.
        if let lastNewline { return lastNewline + 1 }
        // \s+(?!\S) leaves the run's last space for the next piece unless the text ends.
        if runEnd < count, runEnd - start >= 2 { return runEnd - 1 }
        // \s+
        return runEnd
    }
}
