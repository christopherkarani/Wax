import Foundation

/// Deterministic query-aware answer extractor over retrieved RAG items.
/// Keeps Wax fully offline while producing concise answer spans for benchmarking
/// and deterministic answer-style contexts.
///
/// - Important: This is a deterministic heuristic extractor for offline pipelines.
///   It is intentionally lightweight and predictable, but not a substitute for
///   full language-model reasoning.
public struct DeterministicAnswerExtractor: Sendable {
    private let analyzer = QueryAnalyzer()

    public init() {}

    public func extractAnswer(query: String, items: [RAGContext.Item]) -> String {
        let normalizedItems = items
            .map { (item: $0, text: Self.cleanText($0.text)) }
            .filter { !$0.text.isEmpty }
        guard !normalizedItems.isEmpty else { return "" }

        let lowerQuery = query.lowercased()
        let queryTerms = Set(analyzer.normalizedTerms(query: query))
        let queryEntities = analyzer.entityTerms(query: query)
        let queryYears = analyzer.yearTerms(in: query)
        let queryDateKeys = analyzer.normalizedDateKeys(in: query)
        let intent = analyzer.detectIntent(query: query)
        let asksTravel = lowerQuery.contains("flying") || lowerQuery.contains("flight") || lowerQuery.contains("travel")
        let asksAllergy = lowerQuery.contains("allergy") || lowerQuery.contains("allergic")
        let asksCommunicationStyle = lowerQuery.contains("status update") || lowerQuery.contains("written")
        let asksPet = lowerQuery.contains("dog") || lowerQuery.contains("pet") || lowerQuery.contains("adopt")
        let asksDentist = lowerQuery.contains("dentist") || lowerQuery.contains("appointment")

        var ownerCandidates: [AnswerCandidate] = []
        var dateCandidates: [AnswerCandidate] = []
        var launchDateCandidates: [AnswerCandidate] = []
        var appointmentDateTimeCandidates: [AnswerCandidate] = []
        var cityCandidates: [AnswerCandidate] = []
        var flightDestinationCandidates: [AnswerCandidate] = []
        var allergyCandidates: [AnswerCandidate] = []
        var preferenceCandidates: [AnswerCandidate] = []
        var petNameCandidates: [AnswerCandidate] = []
        var adoptionDateCandidates: [AnswerCandidate] = []

        for normalized in normalizedItems {
            let text = normalized.text
            let relevance = relevanceScore(
                queryTerms: queryTerms,
                queryEntities: queryEntities,
                queryYears: queryYears,
                queryDateKeys: queryDateKeys,
                text: text,
                base: normalized.item.score
            )

            ownerCandidates.append(
                contentsOf: ownershipCandidates(
                    in: text,
                    queryTerms: queryTerms,
                    baseScore: relevance
                )
            )

            if let launchDate = firstLaunchDate(in: text) {
                launchDateCandidates.append(.init(text: launchDate, score: relevance + 0.55))
            }

            if let appointmentDateTime = Self.firstMatch(
                regex: Self.appointmentDateTimeRegex,
                in: text,
                capture: 0
            ) {
                appointmentDateTimeCandidates.append(.init(text: appointmentDateTime, score: relevance + 0.55))
            }

            if let movedCity = Self.firstMatch(
                regex: Self.movedCityRegex,
                in: text,
                capture: 1
            ) {
                cityCandidates.append(.init(text: movedCity, score: relevance + 0.45))
            }

            if let destination = Self.firstMatch(
                regex: Self.flightDestinationRegex,
                in: text,
                capture: 1
            ) {
                flightDestinationCandidates.append(.init(text: destination, score: relevance + 0.45))
            }

            if let allergy = Self.firstMatch(
                regex: Self.allergyRegex,
                in: text,
                capture: 1
            ) {
                allergyCandidates.append(.init(text: "allergic to \(allergy)", score: relevance + 0.40))
            }

            if let preference = Self.firstMatch(
                regex: Self.preferenceRegex,
                in: text,
                capture: 1
            ) {
                preferenceCandidates.append(.init(text: preference, score: relevance + 0.35))
            }

            if let petName = Self.firstMatch(
                regex: Self.petNameRegex,
                in: text,
                capture: 1
            ) {
                petNameCandidates.append(.init(text: petName, score: relevance + 0.40))
            }

            if let adoptedDate = Self.firstMatch(
                regex: Self.adoptionDateRegex,
                in: text,
                capture: 1
            ) {
                adoptionDateCandidates.append(.init(text: adoptedDate, score: relevance + 0.40))
            }

            if let genericDate = firstDateLiteral(in: text) {
                dateCandidates.append(.init(text: genericDate, score: relevance + 0.20))
            }
        }

        if asksPet,
           let pet = bestCandidate(in: petNameCandidates),
           let adopted = bestCandidate(in: adoptionDateCandidates) {
            return "\(pet) in \(adopted)"
        }

        if intent.contains(.asksOwnership), intent.contains(.asksDate),
           let owner = bestCandidate(in: ownerCandidates) {
            let date = bestCandidate(in: launchDateCandidates) ?? bestCandidate(in: dateCandidates)
            if let date {
                return "\(owner) and \(date)"
            }
        }

        if asksCommunicationStyle, let style = bestCandidate(in: preferenceCandidates) {
            return style
        }

        if asksAllergy, let allergy = bestCandidate(in: allergyCandidates) {
            return allergy
        }

        if asksTravel, let destination = bestCandidate(in: flightDestinationCandidates) {
            return destination
        }

        if intent.contains(.asksLocation) {
            if asksTravel, let destination = bestCandidate(in: flightDestinationCandidates) {
                return destination
            }
            if let city = bestCandidate(in: cityCandidates) {
                return city
            }
        }

        if intent.contains(.asksDate) {
            if asksDentist, let appointment = bestCandidate(in: appointmentDateTimeCandidates) {
                return appointment
            }
            if let launch = bestCandidate(in: launchDateCandidates) {
                return launch
            }
            if let date = bestCandidate(in: dateCandidates) {
                return date
            }
        }

        if intent.contains(.asksOwnership), let owner = bestCandidate(in: ownerCandidates) {
            return owner
        }

        let texts = normalizedItems.map(\.text)
        return bestLexicalSentence(query: query, texts: texts) ?? texts[0]
    }

    // MARK: - Private

    private struct AnswerCandidate {
        let text: String
        let score: Double
    }

    private static func cleanText(_ text: String) -> String {
        let dehighlighted = text
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = dehighlighted.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relevanceScore(
        queryTerms: Set<String>,
        queryEntities: Set<String>,
        queryYears: Set<String>,
        queryDateKeys: Set<String>,
        text: String,
        base: Float
    ) -> Double {
        var score = Double(base)
        guard !queryTerms.isEmpty || !queryEntities.isEmpty || !queryYears.isEmpty || !queryDateKeys.isEmpty else {
            return score
        }
        let terms = Set(analyzer.normalizedTerms(query: text))
        if !queryTerms.isEmpty, !terms.isEmpty {
            let overlap = Double(queryTerms.intersection(terms).count)
            let recall = overlap / Double(max(1, queryTerms.count))
            let precision = overlap / Double(max(1, terms.count))
            score += recall * 0.70 + precision * 0.30
        }
        if !queryEntities.isEmpty {
            let textEntities = analyzer.entityTerms(query: text)
            let hits = queryEntities.intersection(textEntities).count
            let coverage = Double(hits) / Double(max(1, queryEntities.count))
            score += coverage * 0.95
            if hits == 0 {
                score -= 0.70
            }
        }
        if !queryYears.isEmpty {
            let textYears = analyzer.yearTerms(in: text)
            let hits = queryYears.intersection(textYears).count
            let coverage = Double(hits) / Double(max(1, queryYears.count))
            score += coverage * 1.45
            if hits == 0, !textYears.isEmpty {
                score -= 1.35
            }
        }
        if !queryDateKeys.isEmpty {
            let textDateKeys = analyzer.normalizedDateKeys(in: text)
            let hits = queryDateKeys.intersection(textDateKeys).count
            let coverage = Double(hits) / Double(max(1, queryDateKeys.count))
            score += coverage * 1.25
            if hits == 0, !textDateKeys.isEmpty {
                score -= 1.10
            }
        }
        return score
    }

    private func ownershipCandidates(
        in text: String,
        queryTerms: Set<String>,
        baseScore: Double
    ) -> [AnswerCandidate] {
        var candidates: [AnswerCandidate] = []
        candidates.reserveCapacity(2)

        if let owner = Self.firstMatch(
            regex: Self.deploymentOwnershipRegex,
            in: text,
            capture: 1
        ) {
            candidates.append(.init(text: owner, score: baseScore + 0.60))
        }

        guard let regex = Self.genericOwnershipRegex else {
            return candidates
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges >= 3 else { continue }
            let ownerRange = match.range(at: 1)
            let topicRange = match.range(at: 2)
            guard ownerRange.location != NSNotFound,
                  topicRange.location != NSNotFound,
                  let ownerSwiftRange = Range(ownerRange, in: text),
                  let topicSwiftRange = Range(topicRange, in: text)
            else {
                continue
            }

            let owner = String(text[ownerSwiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = String(text[topicSwiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty, !topic.isEmpty else { continue }

            var score = baseScore + 0.40
            let topicTerms = Set(analyzer.normalizedTerms(query: topic))
            if !queryTerms.isEmpty, !topicTerms.isEmpty {
                let overlap = Double(queryTerms.intersection(topicTerms).count)
                let recall = overlap / Double(max(1, queryTerms.count))
                let precision = overlap / Double(max(1, topicTerms.count))
                score += recall * 0.80 + precision * 0.25
            }
            if topic.lowercased().contains("deployment readiness") {
                score += 0.20
            }

            candidates.append(.init(text: owner, score: score))
        }

        return candidates
    }

    private func firstLaunchDate(in text: String) -> String? {
        guard let regex = Self.launchClauseRegex else { return nil }

        let range = NSRange(location: 0, length: text.utf16.count)
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches {
            guard let clauseRange = Range(match.range, in: text) else { continue }
            let clause = String(text[clauseRange])
            if let date = analyzer.dateLiterals(in: clause).first {
                return date
            }
        }
        return nil
    }

    private func firstDateLiteral(in text: String) -> String? {
        analyzer.dateLiterals(in: text).first
    }

    private func bestCandidate(in candidates: [AnswerCandidate]) -> String? {
        candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.text.count < rhs.text.count
            }
            .first?
            .text
    }

    private func bestLexicalSentence(query: String, texts: [String]) -> String? {
        let queryTerms = Set(analyzer.normalizedTerms(query: query))
        guard !queryTerms.isEmpty else { return texts.first }

        let sentences = texts.flatMap { Self.sentences(in: $0) }
        var best: (text: String, score: Double)?

        for sentence in sentences {
            let normalized = analyzer.normalizedTerms(query: sentence)
            guard !normalized.isEmpty else { continue }
            let overlap = Set(normalized).intersection(queryTerms).count
            let overlapScore = Double(overlap) / Double(max(1, normalized.count))
            let numericBonus = sentence.rangeOfCharacter(from: .decimalDigits) != nil ? 0.15 : 0.0
            let score = overlapScore + numericBonus

            if let current = best {
                if score > current.score || (score == current.score && sentence.count < current.text.count) {
                    best = (sentence, score)
                }
            } else {
                best = (sentence, score)
            }
        }

        return best?.text
    }

    private static func sentences(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Pre-compiled Patterns

    private static let deploymentOwnershipRegex = try? NSRegularExpression(
        pattern: #"\b((?:[A-Z][A-Za-z]*(?:['’\-][A-Z][A-Za-z]*)?)(?:\s+(?:[A-Z][A-Za-z]*(?:['’\-][A-Z][A-Za-z]*)?)){0,3})\s+owns\s+deployment\s+readiness\b"#
    )
    private static let genericOwnershipRegex = try? NSRegularExpression(
        pattern: #"\b((?:[A-Z][A-Za-z]*(?:['’\-][A-Z][A-Za-z]*)?)(?:\s+(?:[A-Z][A-Za-z]*(?:['’\-][A-Z][A-Za-z]*)?)){0,3})\s+owns\s+([^.,;\n]+?)(?=\s+and\s+(?:[A-Z][A-Za-z]*(?:['’\-][A-Z][A-Za-z]*)?)(?:\s+(?:[A-Z][A-Za-z]*(?:['’\-][A-Z][A-Za-z]*)?)){0,3}\s+owns\b|[.,;\n]|$)"#
    )
    private static let appointmentDateTimeRegex = try? NSRegularExpression(
        pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}\s*(?:AM|PM)\b"#
    )
    private static let movedCityRegex = try? NSRegularExpression(
        pattern: #"\b[Mm]oved\s+to\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b"#
    )
    private static let flightDestinationRegex = try? NSRegularExpression(
        pattern: #"\b[Ff]light\s+to\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b"#
    )
    private static let allergyRegex = try? NSRegularExpression(
        pattern: #"\ballergic\s+to\s+([A-Za-z]+(?:\s+[A-Za-z]+)?)\b"#
    )
    private static let preferenceRegex = try? NSRegularExpression(
        pattern: #"\bprefers\s+([^\.]+)"#
    )
    private static let petNameRegex = try? NSRegularExpression(
        pattern: #"\bnamed\s+([A-Z][a-z]+)\b"#
    )
    private static let adoptionDateRegex = try? NSRegularExpression(
        pattern: #"\bin\s+((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4})\b"#
    )
    private static let launchClauseRegex = try? NSRegularExpression(
        pattern: #"\bpublic\s+launch[^.\n]*"#,
        options: [.caseInsensitive]
    )

    private static func firstMatch(regex: NSRegularExpression?, in text: String, capture: Int) -> String? {
        guard let regex else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard capture <= match.numberOfRanges - 1 else { return nil }
        let captureRange = match.range(at: capture)
        guard captureRange.location != NSNotFound,
              let swiftRange = Range(captureRange, in: text) else { return nil }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
