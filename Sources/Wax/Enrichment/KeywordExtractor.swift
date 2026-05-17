import Foundation

/// Deterministic TF-based keyword extraction with simple stopword filtering.
package enum KeywordExtractor {
    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by",
        "can", "could", "did", "do", "does", "for", "from", "had", "has", "have",
        "he", "her", "him", "his", "i", "if", "in", "into", "is", "it", "its",
        "just", "may", "might", "no", "nor", "not", "of", "on", "or", "our", "out",
        "she", "so", "than", "that", "the", "their", "them", "then", "there", "these",
        "they", "this", "those", "to", "too", "was", "we", "were", "what", "when",
        "where", "which", "who", "will", "with", "would", "you", "your"
    ]

    package static func extract(from text: String, topK: Int = 12) -> [String] {
        guard topK > 0 else { return [] }
        guard !text.isEmpty else { return [] }

        let tokens = tokenize(text).flatMap(normalizeToken)
        guard !tokens.isEmpty else { return [] }

        var frequency: [String: Int] = [:]
        var firstSeenIndex: [String: Int] = [:]
        for (index, token) in tokens.enumerated() {
            frequency[token, default: 0] &+= 1
            if firstSeenIndex[token] == nil {
                firstSeenIndex[token] = index
            }
        }

        return frequency
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    let lhsIndex = firstSeenIndex[lhs.key] ?? .max
                    let rhsIndex = firstSeenIndex[rhs.key] ?? .max
                    if lhsIndex != rhsIndex {
                        return lhsIndex < rhsIndex
                    }
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(topK)
            .map(\.key)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split { character in
            !(character.isLetter || character.isNumber || character == "-" || character == "_")
        }
        .map(String.init)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-_")) }
        .filter { !$0.isEmpty }
    }

    private static func normalizeToken(_ token: String) -> [String] {
        let hasIdentifierSeparator = token.contains("-") || token.contains("_")
        let hasUppercase = token.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let isTechnicalIdentifier = (hasIdentifierSeparator && hasTechnicalSeparatorSignal(token))
            || (hasUppercase && hasDigit)
            || isMixedCaseIdentifier(token)

        if isTechnicalIdentifier {
            guard token.count >= 3 else { return [] }
            return [token]
        }

        return proseTerms(from: token)
    }

    private static func proseTerms(from token: String) -> [String] {
        token
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    private static func hasTechnicalSeparatorSignal(_ token: String) -> Bool {
        if token.contains("_") { return true }
        if token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        if isMixedCaseIdentifier(token) { return true }
        let hyphenSegments = token.split(separator: "-").map(String.init)
        if hyphenSegments.contains(where: { isMixedCaseIdentifier($0) || isAcronymSegment($0) }) {
            return true
        }

        let shortNonStopwordSegments = hyphenSegments.filter { segment in
            (2...3).contains(segment.count) && !stopwords.contains(segment.lowercased())
        }
        return shortNonStopwordSegments.count >= 2
    }

    private static func isAcronymSegment(_ token: String) -> Bool {
        let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func isMixedCaseIdentifier(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard scalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) }),
              scalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) else {
            return false
        }

        for index in 1..<scalars.count {
            if CharacterSet.uppercaseLetters.contains(scalars[index]),
               CharacterSet.lowercaseLetters.contains(scalars[index - 1]) {
                return true
            }
            if CharacterSet.lowercaseLetters.contains(scalars[index]),
               CharacterSet.uppercaseLetters.contains(scalars[index - 1]),
               index >= 2,
               CharacterSet.uppercaseLetters.contains(scalars[index - 2]) {
                return true
            }
        }
        return false
    }
}
