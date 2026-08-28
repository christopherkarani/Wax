import Foundation

/// Heuristic query classifier for adaptive fusion (v1).
///
/// This is intentionally deterministic and offline:
/// - no Foundation Models
/// - no network calls
/// - no model downloads
package enum RuleBasedQueryClassifier {
    package static func classify(_ query: String) -> QueryType {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmed.lowercased()

        if q.contains("when")
            || q.contains("yesterday")
            || q.contains("today")
            || q.contains("last ")
            || q.contains("recent")
            || q.contains("latest")
            || q.contains("before ")
            || q.contains("after ")
            || q.contains("between ") {
            return .temporal
        }

        if q.hasPrefix("what is")
            || q.hasPrefix("what are")
            || q.hasPrefix("who is")
            || q.hasPrefix("who are")
            || q.contains("define ")
            || q.contains("definition of")
            || q.contains("meaning of") {
            return .factual
        }

        if q.contains("how ")
            || q.contains("why ")
            || q.contains("explain")
            || q.contains("describe")
            || q.contains("relate") {
            return .semantic
        }

        // Identifier / hex / single-token canaries are lexical lookups, not exploration.
        if isLexicalIdentifierQuery(trimmed) {
            return .factual
        }

        return .exploratory
    }

    private static let hexScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    /// Single-token hex / identifier canaries (not ordinary English words).
    package static func isLexicalIdentifierQuery(_ query: String) -> Bool {
        let tokens = query.split { $0.isWhitespace || $0.isNewline }
        guard tokens.count == 1 else { return false }
        let token = tokens[0]
        guard !token.isEmpty else { return false }
        // Keep this intentionally narrow to one token: ordinary bare words stay
        // exploratory, while IDs that use common path/name punctuation can take
        // the lexical lane. MatchPlan still controls how the token is planned for
        // FTS and preserves '-'/'_' glue for the #166 path.
        let identifierPunctuation = CharacterSet(charactersIn: "-_.:/@#%+")
        let allowed = CharacterSet.alphanumerics.union(identifierPunctuation)
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasIdentifierPunctuation = token.unicodeScalars.contains { identifierPunctuation.contains($0) }
        if hasDigit || hasIdentifierPunctuation {
            return true
        }

        // CamelCase identifiers are common exact lookups (for example,
        // `AgentBrokerClient`) but a leading-capital human name such as
        // `Swift` or `Noah` is still ordinary prose. Require an uppercase
        // transition after the first scalar before treating letters-only text
        // as an implicit exact query.
        if token.unicodeScalars.dropFirst().contains(where: { CharacterSet.uppercaseLetters.contains($0) }) {
            return true
        }

        // Letter-only hex such as `DEADBEEF`. Digit hex (`7f3a91`) already matched.
        // Length 8 avoids English hex-words (`facade`, `decade`).
        return token.count >= 8 && token.unicodeScalars.allSatisfy { hexScalars.contains($0) }
    }

    /// Whether an omitted retrieval mode should use the lexical lane.
    ///
    /// An explicit identifier (including UUIDs, dotted/underscored names, and
    /// path-like IDs) or a quoted phrase is an exact-intent lookup. Plain bare
    /// words and ordinary prose remain on the configured default mode so this
    /// does not turn every name-like word into a lexical query.
    package static func isExactIntentQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLexicalIdentifierQuery(trimmed) {
            return true
        }
        return !MatchPlan.rawQuotedPhrases(from: trimmed).isEmpty
    }
}
