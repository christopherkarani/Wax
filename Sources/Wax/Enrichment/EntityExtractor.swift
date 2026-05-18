import Foundation

/// Deterministic offline entity extraction for async enrichment.
package enum EntityExtractor {
    package static func extract(from text: String, topK: Int = 16) -> [EnrichmentEntity] {
        guard topK > 0 else { return [] }

        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }

        var entities: [EnrichmentEntity] = []
        var seen: Set<String> = []

        func append(_ subject: String) {
            let normalized = StructuredMemoryCanonicalizer.normalizedAlias(subject)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            entities.append(
                EnrichmentEntity(
                    subject: subject,
                    predicate: "mentioned_in",
                    object: "source_text"
                )
            )
        }

        for token in tokens where isIdentifierLike(token.text) {
            append(token.text)
            if entities.count >= topK { return entities }
        }

        var index = 0
        while index < tokens.count {
            guard isTitleToken(tokens[index].text), !isNoise(tokens[index].text) else {
                index += 1
                continue
            }

            var end = index + 1
            while end < tokens.count,
                  end - index < 4,
                  isTitleToken(tokens[end].text),
                  !isNoise(tokens[end].text) {
                end += 1
            }

            if end - index >= 2 {
                append(tokens[index..<end].map(\.text).joined(separator: " "))
                if entities.count >= topK { return entities }
            }

            index = max(end, index + 1)
        }

        return entities
    }

    private struct Token {
        var text: String
    }

    private static func tokenize(_ text: String) -> [Token] {
        text.split { character in
            !(character.isLetter || character.isNumber || character == "-" || character == "_")
        }
        .map(String.init)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-_")) }
        .filter { !$0.isEmpty }
        .map(Token.init(text:))
    }

    private static func isIdentifierLike(_ token: String) -> Bool {
        let hasLetter = token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        return hasLetter && hasDigit
    }

    private static func isTitleToken(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first else { return false }
        guard CharacterSet.uppercaseLetters.contains(first) else { return false }
        return token.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
    }

    private static func isNoise(_ token: String) -> Bool {
        let normalized = StructuredMemoryCanonicalizer.normalizedAlias(token)
        return normalized.count < 3 || noiseTerms.contains(normalized)
    }

    private static let noiseTerms: Set<String> = [
        "the", "this", "that", "these", "those", "swift", "wax", "memory",
        "review", "launch", "assigned", "stores", "durable", "keywords"
    ]
}
