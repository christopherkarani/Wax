import Foundation

/// Shared, vocabulary-independent answer-shape signals used by Ranking
/// (`UnifiedRanking.intentAwareRerank`) and Recall assembly
/// (`FastRAGContextBuilder.orderCandidatesForAnswer`).
///
/// Keep these signals general: hedging language, sentence shapes that answer a
/// detected intent. Do not add phrases taken from a benchmark or fixture corpus.
enum RerankingHelpers {

    /// True when the text hedges a stated value (tentative / unconfirmed).
    /// Date-intent ranking penalizes these so a confirmed statement wins.
    static func containsTentativeLanguage(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("tentative")
            || lowercasedText.contains("draft")
            || lowercasedText.contains("proposed")
            || lowercasedText.contains("pending approval")
            || lowercasedText.contains("target is")
            || lowercasedText.contains("target date")
            || lowercasedText.contains("could be")
            || lowercasedText.contains("estimate")
    }

    /// True when the text states a relocation to a named place
    /// (for example "moved to Lisbon"). Case-sensitive on the place name.
    static func containsRelocationStatement(_ text: String) -> Bool {
        guard let regex = relocationRegex else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// True when the text names an owner ("X owns Y", "owner: X").
    static func containsOwnershipStatement(_ lowercasedText: String) -> Bool {
        lowercasedText.contains(" owns ") || lowercasedText.contains("owner")
    }

    private static let relocationRegex = try? NSRegularExpression(
        pattern: #"\b(?:moved|move|relocated|relocate)\s+to\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b"#
    )
}
