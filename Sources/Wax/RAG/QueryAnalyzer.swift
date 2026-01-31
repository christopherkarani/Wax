import Foundation

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
}
