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
    private static func isLexicalIdentifierQuery(_ query: String) -> Bool {
        let tokens = query.split { $0.isWhitespace || $0.isNewline }
        guard tokens.count == 1 else { return false }
        let token = tokens[0]
        guard !token.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let identifierPunctuation = CharacterSet(charactersIn: "-_.")
        let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasIdentifierPunctuation = token.unicodeScalars.contains { identifierPunctuation.contains($0) }
        if hasDigit || hasIdentifierPunctuation {
            return true
        }

        // Letter-only hex such as `DEADBEEF`. Digit hex (`7f3a91`) already matched.
        // Length 8 avoids English hex-words (`facade`, `decade`).
        return token.count >= 8 && token.unicodeScalars.allSatisfy { hexScalars.contains($0) }
    }
}

