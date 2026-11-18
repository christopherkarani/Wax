import Foundation

/// Shared, vocabulary-independent answer-shape signals used by Ranking
/// (`UnifiedRanking.intentAwareRerank`) and Recall assembly
/// (`FastRAGContextBuilder.orderCandidatesForAnswer`).
///
/// Keep these signals general: hedging language, sentence shapes that answer a
/// detected intent. Match whole words, never substrings ("drafted" is not
/// "draft"). Do not add phrases taken from a benchmark or fixture corpus.
enum RerankingHelpers {

    /// True when the text hedges a stated value (tentative / unconfirmed).
    /// Date-intent ranking penalizes these so a confirmed statement wins.
    static func containsTentativeLanguage(_ lowercasedText: String) -> Bool {
        let words = Self.words(lowercasedText)
        if words.contains(where: tentativeWords.contains) { return true }
        return tentativePhrases.contains { containsPhrase($0, in: words) }
    }

    /// True when the text states a relocation to a named place
    /// (for example "moved to Lisbon"). Case-sensitive on the place name;
    /// weekdays, months and other calendar words are not places.
    static func containsRelocationStatement(_ text: String) -> Bool {
        guard let regex = relocationRegex else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Weaker relocation cue: "moved to <word>" where the word is not a
    /// calendar or clock reference ("moved to friday", "moved to 3pm").
    static func containsMoveToPhrase(_ lowercasedText: String) -> Bool {
        let words = Self.words(lowercasedText)
        guard words.count >= 3 else { return false }
        for index in 0..<(words.count - 2) where moveVerbs.contains(words[index]) && words[index + 1] == "to" {
            let target = words[index + 2]
            if calendarWords.contains(target) { continue }
            if target.first?.isNumber == true { continue }
            return true
        }
        return false
    }

    /// True when the text names an owner ("X owns Y", "owner: X").
    static func containsOwnershipStatement(_ lowercasedText: String) -> Bool {
        Self.words(lowercasedText).contains(where: ownershipWords.contains)
    }

    /// Lowercased text split into letter/number words.
    static func words(_ lowercasedText: String) -> [Substring] {
        lowercasedText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    private static func containsPhrase(_ phrase: [Substring], in words: [Substring]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count)
            where words[start..<(start + phrase.count)].elementsEqual(phrase) {
            return true
        }
        return false
    }

    private static let tentativeWords: Set<Substring> = [
        "tentative", "tentatively", "draft", "proposed", "estimate", "unconfirmed",
    ]

    private static let tentativePhrases: [[Substring]] = [
        ["pending", "approval"], ["target", "is"], ["target", "date"], ["could", "be"],
    ]

    private static let ownershipWords: Set<Substring> = ["owns", "owner", "owners"]

    private static let moveVerbs: Set<Substring> = [
        "move", "moved", "moves", "moving", "relocate", "relocated", "relocating",
    ]

    private static let calendarNames = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "today", "tomorrow", "tonight", "yesterday", "next", "later", "noon", "midnight",
        "morning", "afternoon", "evening", "q1", "q2", "q3", "q4",
    ]

    private static let calendarWords: Set<Substring> = Set(calendarNames.map { Substring($0) })

    private static let relocationRegex: NSRegularExpression? = {
        let calendar = calendarNames.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: "|")
        let pattern = #"\b(?:moved|move|moves|moving|relocated|relocate|relocating)\s+to\s+"#
            + "(?!(?:\(calendar))\\b)"
            + #"[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b"#
        return try? NSRegularExpression(pattern: pattern)
    }()
}
