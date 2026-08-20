import Foundation

/// Ranking's text-lane interface: AND MATCH first, optional OR MATCH, token count.
/// Empty plan (stopwords / operators only) means no text hits — never the raw query.
package struct MatchPlan: Equatable, Sendable {
    package let primaryMatch: String
    package let fallbackMatch: String?
    package let tokenCount: Int

    package static func plan(query: String, maxTokens: Int = 16) -> MatchPlan? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokenList = tokens(from: trimmed, maxTokens: maxTokens)
        let phrases = normalizedQuotedPhrases(from: trimmed)
        guard let primary = matchQuery(phrases: phrases, tokens: tokenList, join: .andLike) else {
            return nil
        }
        let fallback = matchQuery(phrases: phrases, tokens: tokenList, join: .or)
        return MatchPlan(
            primaryMatch: primary,
            fallbackMatch: (fallback != nil && fallback != primary) ? fallback : nil,
            tokenCount: tokenList.count
        )
    }

    package static func tokens(from query: String, maxTokens: Int = 16) -> [String] {
        let capped = max(0, maxTokens)
        guard capped > 0 else { return [] }
        var seen: Set<String> = []
        var tokens: [String] = []
        tokens.reserveCapacity(capped)

        for token in aliasTokens(from: query) {
            let normalized = token.lowercased()
            guard !normalized.isEmpty else { continue }
            guard !ftsStopWords.contains(normalized) else { continue }
            let hasLettersOrDigits = normalized.unicodeScalars.contains {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            guard hasLettersOrDigits else { continue }
            if seen.insert(normalized).inserted {
                tokens.append(normalized)
                if tokens.count >= capped { break }
            }
        }

        return tokens
    }

    package static func aliasTokens(from query: String) -> [String] {
        var tokens: [String] = []
        var buffer = String.UnicodeScalarView()

        func flush() {
            if !buffer.isEmpty {
                tokens.append(String(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in query.unicodeScalars {
            if scalar.properties.isWhitespace || (scalar.isASCII && asciiPunctuationScalars.contains(scalar)) {
                flush()
            } else {
                buffer.append(scalar)
            }
        }
        flush()

        return tokens
    }

    package static func rawQuotedPhrases(from query: String, maxPhrases: Int = 4) -> [String] {
        let range = NSRange(location: 0, length: query.utf16.count)
        var matches: [(location: Int, phrase: String)] = []

        for regex in quotedPhraseRegexes {
            for match in regex.matches(in: query, range: range) {
                let capture = match.range(at: 1)
                guard capture.location != NSNotFound,
                      let swiftRange = Range(capture, in: query)
                else {
                    continue
                }
                let phrase = query[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { continue }
                matches.append((location: capture.location, phrase: String(phrase)))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.phrase.count < rhs.phrase.count
        }

        var seen: Set<String> = []
        var phrases: [String] = []
        phrases.reserveCapacity(min(maxPhrases, matches.count))
        for match in matches {
            guard phrases.count < maxPhrases else { break }
            let hasSignal = match.phrase.unicodeScalars.contains {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            guard hasSignal else { continue }
            let key = match.phrase.lowercased()
            if seen.insert(key).inserted {
                phrases.append(match.phrase)
            }
        }
        return phrases
    }

    package static func normalizedQuotedPhrases(
        from query: String,
        maxPhrases: Int = 4,
        maxTokensPerPhrase: Int = 8
    ) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for phrase in rawQuotedPhrases(from: query, maxPhrases: maxPhrases) {
            let phraseTokens = tokens(from: phrase, maxTokens: maxTokensPerPhrase)
            guard !phraseTokens.isEmpty else { continue }
            let value = phraseTokens.joined(separator: " ")
            if seen.insert(value).inserted {
                normalized.append(value)
            }
        }

        return normalized
    }

    private enum FTSMatchJoin {
        case andLike
        case or

        var separator: String {
            switch self {
            case .andLike: " "
            case .or: " OR "
            }
        }
    }

    private static func matchQuery(
        phrases: [String],
        tokens: [String],
        join: FTSMatchJoin
    ) -> String? {
        let quotedPhrases = phrases.map(quotedFTSLiteral)
        let quotedTokens = tokens.map(quotedFTSLiteral)
        let clauses = quotedPhrases + quotedTokens
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: join.separator)
    }

    private static func quotedFTSLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static let ftsStopWords: Set<String> = [
        "a", "an", "and", "are", "at", "did", "do", "for", "from", "in", "is", "of",
        "on", "or", "the", "to", "what", "when", "where", "which", "who", "with",
        "date",
        "not", "near",
    ]

    private static let asciiPunctuationScalars: Set<UnicodeScalar> = {
        let scalars = "!\\\"#$%&'()*+,-./:;<=>?@[\\\\]^_`{|}~".unicodeScalars
        return Set(scalars)
    }()

    private static let quotedPhraseRegexes: [NSRegularExpression] = {
        let patterns = [
            #""([^"]+)""#,
            #"'([^']+)'"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}
