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

        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                token.count >= 3 && !stopwords.contains(token)
            }
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
}
