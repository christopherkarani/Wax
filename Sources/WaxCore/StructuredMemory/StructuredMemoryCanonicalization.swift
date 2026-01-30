import Foundation

/// Canonicalization helpers for structured memory keys and aliases.
public enum StructuredMemoryCanonicalizer {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public static func normalizedString(_ input: String) -> String {
        let nfkc = input.precomposedStringWithCompatibilityMapping
        return nfkc.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posixLocale)
    }

    public static func normalizedAlias(_ input: String) -> String {
        let normalized = normalizedString(input)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}
