import Foundation

public struct QueryIntent: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let asksLocation = QueryIntent(rawValue: 1 << 0)
    public static let asksDate = QueryIntent(rawValue: 1 << 1)
    public static let asksOwnership = QueryIntent(rawValue: 1 << 2)
    public static let multiHop = QueryIntent(rawValue: 1 << 3)
}

/// Query characteristics that influence tier selection.
public struct QuerySignals: Sendable, Equatable {
    /// Query contains specific entities (names, dates, numbers)
    public var hasSpecificEntities: Bool
    
    /// Number of words in the query
    public var wordCount: Int
    
    /// Query contains quoted phrases (exact match intent)
    public var hasQuotedPhrases: Bool
    
    /// Estimated specificity score (0.0 = vague, 1.0 = very specific)
    public var specificityScore: Float
}

/// Analyzes queries to extract signals for tier selection.
public struct QueryAnalyzer: Sendable {
    public init() {}
    
    /// Analyze a query to extract signals that influence tier selection.
    ///
    /// Specific queries (with entities, quotes) should use fuller tiers,
    /// while vague queries can use more compressed tiers.
    public func analyze(query: String) -> QuerySignals {
        let words = query.split { $0.isWhitespace || $0.isPunctuation }
        
        // Check for specific entities (numbers, capitalized words)
        let hasNumbers = query.rangeOfCharacter(from: .decimalDigits) != nil
        let hasCapitalized = words.contains { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }
        let hasSpecificEntities = hasNumbers || hasCapitalized
        
        // Check for quoted phrases (indicates exact match intent)
        let hasQuotedPhrases = query.contains("\"")
        
        // Calculate specificity score (0.0 to 1.0)
        var specificity: Float = 0.0
        
        // Longer queries tend to be more specific
        // Max 0.4 contribution at 8+ words
        specificity += min(Float(words.count) / 8.0, 0.4)
        
        // Entities indicate specific intent
        if hasSpecificEntities {
            specificity += 0.35
        }
        
        // Quoted phrases indicate exact match requirements
        if hasQuotedPhrases {
            specificity += 0.25
        }
        
        return QuerySignals(
            hasSpecificEntities: hasSpecificEntities,
            wordCount: words.count,
            hasQuotedPhrases: hasQuotedPhrases,
            specificityScore: min(1.0, specificity)
        )
    }

    /// Normalize query text into deterministic lexical terms for matching/reranking.
    public func normalizedTerms(query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .map(normalizeToken)
            .filter { !$0.isEmpty && !Self.stopWords.contains($0) }
    }

    /// Extract entity-like terms (for example: "person18", "atlas10") for intent-aware reranking.
    public func entityTerms(query: String) -> Set<String> {
        let original = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        let raw = original.map { $0.lowercased() }
        guard !raw.isEmpty else { return [] }

        var entities: Set<String> = []
        entities.reserveCapacity(raw.count)

        for token in raw where Self.containsLetters(token) && Self.containsDigits(token) {
            entities.insert(token)
        }

        if raw.count > 1 {
            for index in 0..<(raw.count - 1) {
                let lhs = raw[index]
                let rhs = raw[index + 1]
                if Self.isLettersOnly(lhs), Self.isDigitsOnly(rhs) {
                    entities.insert(lhs + rhs)
                }
            }
        }

        if !original.isEmpty {
            for (index, token) in original.enumerated() {
                let normalized = token.lowercased()
                guard Self.isLettersOnly(normalized) else { continue }
                guard normalized.count >= 3 else { continue }
                guard !Self.stopWords.contains(normalized) else { continue }
                guard !Self.entityNoiseTerms.contains(normalized) else { continue }

                let hasUppercase = token.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
                let hasEntityCue =
                    index > 0 &&
                    Self.entityCueWords.contains(raw[index - 1]) &&
                    normalized.count >= 4

                if hasUppercase || hasEntityCue {
                    entities.insert(normalized)
                }
            }
        }

        return entities
    }

    public func detectIntent(query: String) -> QueryIntent {
        let lower = query.lowercased()
        let terms = Set(normalizedTerms(query: query))

        var intent: QueryIntent = []
        if lower.contains("city")
            || lower.contains("where")
            || terms.contains("move")
            || terms.contains("moved")
        {
            intent.insert(.asksLocation)
        }
        if lower.contains("date")
            || lower.contains("when")
            || lower.contains("launch")
            || lower.contains("timeline")
        {
            intent.insert(.asksDate)
        }
        if lower.contains("who")
            || lower.contains("owner")
            || lower.contains("owns")
            || lower.contains("deployment readiness")
        {
            intent.insert(.asksOwnership)
        }
        let enabledIntentCount =
            (intent.contains(.asksLocation) ? 1 : 0) +
            (intent.contains(.asksDate) ? 1 : 0) +
            (intent.contains(.asksOwnership) ? 1 : 0)
        if lower.contains(" and ") && enabledIntentCount > 1 {
            intent.insert(.multiHop)
        }
        return intent
    }

    // MARK: - Private

    private func normalizeToken(_ token: String) -> String {
        guard token.count > 3 else { return token }
        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("ing"), token.count > 5 {
            return String(token.dropLast(3))
        }
        if token.hasSuffix("ed"), token.count > 4 {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("es"), token.count > 4 {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("s"), token.count > 4 {
            return String(token.dropLast())
        }
        return token
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "at", "did", "do", "for", "from", "in", "is", "of",
        "on", "or", "the", "to", "what", "when", "where", "which", "who", "with"
    ]

    private static let entityCueWords: Set<String> = [
        "for", "about", "did", "does", "with", "from"
    ]

    private static let entityNoiseTerms: Set<String> = [
        "city", "date", "owner", "owns", "launch", "public", "project", "beta",
        "deployment", "readiness", "timeline", "status", "updates", "update",
        "report", "checklist", "signoff", "team", "health", "allergic",
    ]

    private static func containsLetters(_ token: String) -> Bool {
        token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func containsDigits(_ token: String) -> Bool {
        token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isLettersOnly(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func isDigitsOnly(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}
