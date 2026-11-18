/// Splits text into the pieces the cl100k_base pre-tokenizer regex matches
/// (``NativeBpeTokenizer/cl100kBasePattern``) without running ICU.
///
/// The scanner works on one unit byte per Unicode scalar, as ICU matches code points. For
/// ASCII, `\p{L}` is `[A-Za-z]`, `\p{N}` is `[0-9]` and ICU's `\s` is
/// `[\t\n\u{0B}\u{0C}\r ]`, and the unit is the byte itself. Beyond ASCII, `\p{L}` is a
/// letter category (Lu, Ll, Lt, Lm, Lo), `\p{N}` a number category (Nd, Nl, No) and `\s` the
/// White_Space property, while `[\r\n]`, `'` and ` ` stay ASCII. The scanner compares units
/// only with those ASCII characters and with the contraction letters, and reads every other
/// property from the unit's class, so a non-ASCII scalar's unit is just its class above
/// 0x80. The one exception is U+017F LATIN SMALL LETTER LONG S, which `(?i)` matches as `s`
/// in a contraction and so gets the unit `s`. The scanner tries the pattern's alternatives
/// in order and returns the match the regex engine's backtracking would. Every scalar
/// starts some match, so the pieces cover the text.
///
/// ICU's character data can differ from the standard library's: Apple's ICU gives some
/// private-use characters letter and digit properties, and an ICU built on an older Unicode
/// version treats recent characters as unassigned. Text holding a private-use or unassigned
/// scalar, or one first assigned after Unicode `newestTrustedUnicodeMajorVersion`, returns
/// nil so the caller runs the regex.
package enum Cl100kPreTokenizer {
    private static let letter: UInt8 = 1
    private static let digit: UInt8 = 2
    private static let space: UInt8 = 4
    private static let newline: UInt8 = 8
    /// Set in the unit of every non-ASCII scalar except U+017F.
    private static let nonASCIIUnit: UInt8 = 0x80

    private static let newestTrustedUnicodeMajorVersion = 14

    /// The class of each unit: ASCII bytes by the regex's ASCII classes, non-ASCII units by
    /// the class bits below `nonASCIIUnit`.
    private static let classes: [UInt8] = (0..<256).map { unit in
        switch unit {
        case 0x41...0x5A, 0x61...0x7A: letter
        case 0x30...0x39: digit
        case 0x0A, 0x0D: space | newline
        case 0x09, 0x0B, 0x0C, 0x20: space
        case 0x80...: UInt8(unit) & ~nonASCIIUnit
        default: 0
        }
    }

    /// Byte ranges of the pieces of `bytes` (UTF-8), in order, or nil when the text holds a
    /// scalar ICU may class differently or is not valid UTF-8.
    package static func pieceRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>]? {
        if bytes.allSatisfy({ $0 < 0x80 }) { return pieceRanges(units: bytes) }

        var units: [UInt8] = []
        var offsets: [Int] = []
        units.reserveCapacity(bytes.count)
        offsets.reserveCapacity(bytes.count + 1)
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var offset = 0
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                guard let unit = unit(for: scalar) else { return nil }
                units.append(unit)
                offsets.append(offset)
                offset += UTF8.width(scalar)
            case .emptyInput:
                break decoding
            case .error:
                return nil
            }
        }
        offsets.append(offset)
        return units.withUnsafeBufferPointer(pieceRanges(units:)).map {
            offsets[$0.lowerBound]..<offsets[$0.upperBound]
        }
    }

    /// The scanner's unit for `scalar`, or nil when ICU may class it differently.
    private static func unit(for scalar: Unicode.Scalar) -> UInt8? {
        if scalar.isASCII { return UInt8(scalar.value) }
        if scalar.value == 0x17F { return UInt8(ascii: "s") }
        let properties = scalar.properties
        guard let age = properties.age, age.major <= newestTrustedUnicodeMajorVersion else { return nil }
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return nonASCIIUnit | letter
        case .decimalNumber, .letterNumber, .otherNumber:
            return nonASCIIUnit | digit
        case .privateUse, .unassigned, .surrogate:
            return nil
        default:
            return properties.isWhitespace ? nonASCIIUnit | space : nonASCIIUnit
        }
    }

    /// Unit ranges of the pieces, in order.
    private static func pieceRanges(units: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < units.count {
            let end = pieceEnd(units, from: start)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private static func pieceEnd(_ units: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let count = units.count
        func kind(_ index: Int) -> UInt8 { classes[Int(units[index])] }
        func lowered(_ index: Int) -> UInt8 { units[index] | 0x20 }

        // (?i:'s|'t|'re|'ve|'m|'ll|'d)
        if units[start] == UInt8(ascii: "'"), start + 1 < count {
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
        if units[start] == UInt8(ascii: " "), start + 1 < count, kind(start + 1) & other == 0 {
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
