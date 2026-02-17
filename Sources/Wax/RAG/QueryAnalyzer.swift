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
                let hasNameFollowerCue =
                    index + 1 < raw.count &&
                    Self.nameFollowerCueWords.contains(raw[index + 1]) &&
                    normalized.count >= 4

                if hasUppercase || hasEntityCue || hasNameFollowerCue {
                    entities.insert(normalized)
                }
            }
        }

        return entities
    }

    /// Four-digit year cues extracted from text (for timeline disambiguation).
    public func yearTerms(in text: String) -> Set<String> {
        Set(
            text
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter {
                    $0.count == 4 &&
                    $0.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
                }
        )
    }

    /// Date literals in encounter order.
    ///
    /// Supported deterministic formats:
    /// - `Month D, YYYY` and `Month D YYYY` (full + abbreviated months)
    /// - `D Month YYYY` and `D Mon YYYY`
    /// - ISO-like `YYYY-MM-DD`, plus `/` or `.` separators and 1-2 digit month/day
    public func dateLiterals(in text: String) -> [String] {
        let full = Self.captureMatches(regex: Self.fullMonthDateRegex, text: text, captureGroup: 0)
        let abbreviated = Self.captureMatches(regex: Self.abbreviatedMonthDateRegex, text: text, captureGroup: 0)
        let dayFirst = Self.captureMatches(regex: Self.dayFirstMonthDateRegex, text: text, captureGroup: 0)
        let iso = Self.captureMatches(regex: Self.isoDateRegex, text: text, captureGroup: 0)

        let all = (full + abbreviated + dayFirst + iso)
            .sorted { lhs, rhs in
                if lhs.location != rhs.location { return lhs.location < rhs.location }
                return lhs.value.count < rhs.value.count
            }

        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(all.count)
        for item in all {
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.normalizedDateKey(from: value) != nil else {
                continue
            }
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }

    /// Normalized date keys in ISO form (YYYY-MM-DD) across supported date literal formats.
    public func normalizedDateKeys(in text: String) -> Set<String> {
        let literals = dateLiterals(in: text)
        var keys: Set<String> = []
        keys.reserveCapacity(literals.count)

        for literal in literals {
            if let key = Self.normalizedDateKey(from: literal) {
                keys.insert(key)
            }
        }

        return keys
    }

    /// True when any supported date literal is present.
    public func containsDateLiteral(_ text: String) -> Bool {
        !dateLiterals(in: text).isEmpty
    }

    public func detectIntent(query: String) -> QueryIntent {
        let lower = query.lowercased()
        let terms = Set(normalizedTerms(query: query))

        var intent: QueryIntent = []
        if lower.contains("city")
            || lower.contains("where")
            || terms.contains("move")
            || terms.contains("mov")
            || lower.contains("moved")
            || lower.contains("moving")
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

    private static let nameFollowerCueWords: Set<String> = [
        "moved", "move", "owns", "owned", "launch", "launched"
    ]

    private static let entityNoiseTerms: Set<String> = [
        "city", "date", "owner", "owns", "launch", "public", "project", "beta",
        "deployment", "readiness", "timeline", "status", "updates", "update",
        "report", "checklist", "signoff", "team", "health", "allergic",
    ]

    private static let fullMonthDateRegex = try? NSRegularExpression(
        pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,\s*|\s+)\d{4}\b"#,
        options: [.caseInsensitive]
    )

    private static let abbreviatedMonthDateRegex = try? NSRegularExpression(
        pattern: #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+\d{1,2}(?:,\s*|\s+)\d{4}\b"#,
        options: [.caseInsensitive]
    )

    private static let dayFirstMonthDateRegex = try? NSRegularExpression(
        pattern: #"\b\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?(?:,\s*|\s+)\d{4}\b"#,
        options: [.caseInsensitive]
    )

    private static let isoDateRegex = try? NSRegularExpression(
        pattern: #"\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b"#,
        options: []
    )

    private static let monthByName: [String: Int] = [
        "january": 1, "jan": 1,
        "february": 2, "feb": 2,
        "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "may": 5,
        "june": 6, "jun": 6,
        "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12,
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

    private static func captureMatches(
        regex: NSRegularExpression?,
        text: String,
        captureGroup: Int
    ) -> [(location: Int, value: String)] {
        guard let regex else { return [] }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard captureGroup < match.numberOfRanges else { return nil }
            let capture = match.range(at: captureGroup)
            guard capture.location != NSNotFound,
                  let swiftRange = Range(capture, in: text)
            else {
                return nil
            }
            return (location: capture.location, value: String(text[swiftRange]))
        }
    }

    private static func normalizedDateKey(from literal: String) -> String? {
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        if let isoMatch = captureMatches(regex: isoDateRegex, text: trimmed, captureGroup: 0).first,
           isoMatch.value == trimmed {
            let components = trimmed
                .split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." })
                .map(String.init)
            guard components.count == 3,
                  let year = Int(components[0]),
                  let month = Int(components[1]),
                  let day = Int(components[2]),
                  isValidCalendarDate(year: year, month: month, day: day)
            else {
                return nil
            }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }

        let parts = trimmed
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 3 else { return nil }

        let first = parts[0].lowercased().replacingOccurrences(of: ".", with: "")
        let second = parts[1].lowercased().replacingOccurrences(of: ".", with: "")
        let third = parts[2]

        let year: Int
        let month: Int
        let day: Int

        if let parsedMonth = monthByName[first],
           let parsedDay = Int(parts[1]),
           let parsedYear = Int(third) {
            year = parsedYear
            month = parsedMonth
            day = parsedDay
        } else if let parsedDay = Int(parts[0]),
                  let parsedMonth = monthByName[second],
                  let parsedYear = Int(third) {
            year = parsedYear
            month = parsedMonth
            day = parsedDay
        } else {
            return nil
        }

        guard isValidCalendarDate(year: year, month: month, day: day) else { return nil }

        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func isValidCalendarDate(year: Int, month: Int, day: Int) -> Bool {
        guard (1900...2999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            return false
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)

        guard let date = gregorianUTC.date(from: components) else {
            return false
        }
        let resolved = gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}
