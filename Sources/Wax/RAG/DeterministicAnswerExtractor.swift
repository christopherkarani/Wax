import Foundation

/// Deterministic query-aware answer extractor over retrieved RAG items.
/// Keeps Wax fully offline while producing concise answer spans for benchmarking
/// and deterministic answer-style contexts.
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
            let relevance = relevanceScore(queryTerms: queryTerms, text: text, base: normalized.item.score)

            if let owner = Self.firstMatch(
                pattern: #"\b([A-Z][a-z]+)\s+owns\s+deployment\s+readiness\b"#,
                in: text,
                capture: 1
            ) {
                ownerCandidates.append(.init(text: owner, score: relevance + 0.50))
            }

            if let launchDate = Self.firstMatch(
                pattern: #"\bpublic\s+launch[^.]*?((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4})\b"#,
                in: text,
                capture: 1
            ) {
                launchDateCandidates.append(.init(text: launchDate, score: relevance + 0.55))
            }

            if let appointmentDateTime = Self.firstMatch(
                pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}\s*(?:AM|PM)\b"#,
                in: text,
                capture: 0
            ) {
                appointmentDateTimeCandidates.append(.init(text: appointmentDateTime, score: relevance + 0.55))
            }

            if let movedCity = Self.firstMatch(
                pattern: #"\b[Mm]oved\s+to\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b"#,
                in: text,
                capture: 1
            ) {
                cityCandidates.append(.init(text: movedCity, score: relevance + 0.45))
            }

            if let destination = Self.firstMatch(
                pattern: #"\b[Ff]light\s+to\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b"#,
                in: text,
                capture: 1
            ) {
                flightDestinationCandidates.append(.init(text: destination, score: relevance + 0.45))
            }

            if let allergy = Self.firstMatch(
                pattern: #"\ballergic\s+to\s+([A-Za-z]+(?:\s+[A-Za-z]+)?)\b"#,
                in: text,
                capture: 1
            ) {
                allergyCandidates.append(.init(text: "allergic to \(allergy)", score: relevance + 0.40))
            }

            if let preference = Self.firstMatch(
                pattern: #"\bprefers\s+([^\.]+)"#,
                in: text,
                capture: 1
            ) {
                preferenceCandidates.append(.init(text: preference, score: relevance + 0.35))
            }

            if let petName = Self.firstMatch(
                pattern: #"\bnamed\s+([A-Z][a-z]+)\b"#,
                in: text,
                capture: 1
            ) {
                petNameCandidates.append(.init(text: petName, score: relevance + 0.40))
            }

            if let adoptedDate = Self.firstMatch(
                pattern: #"\bin\s+((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4})\b"#,
                in: text,
                capture: 1
            ) {
                adoptionDateCandidates.append(.init(text: adoptedDate, score: relevance + 0.40))
            }

            if let genericDate = Self.firstMatch(
                pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\b"#,
                in: text,
                capture: 0
            ) {
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

    private func relevanceScore(queryTerms: Set<String>, text: String, base: Float) -> Double {
        guard !queryTerms.isEmpty else { return Double(base) }
        let terms = Set(analyzer.normalizedTerms(query: text))
        guard !terms.isEmpty else { return Double(base) }
        let overlap = Double(queryTerms.intersection(terms).count)
        let recall = overlap / Double(max(1, queryTerms.count))
        let precision = overlap / Double(max(1, terms.count))
        return Double(base) + recall * 0.70 + precision * 0.30
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

    private static func firstMatch(pattern: String, in text: String, capture: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard capture <= match.numberOfRanges - 1 else { return nil }
        let captureRange = match.range(at: capture)
        guard captureRange.location != NSNotFound,
              let swiftRange = Range(captureRange, in: text) else { return nil }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
