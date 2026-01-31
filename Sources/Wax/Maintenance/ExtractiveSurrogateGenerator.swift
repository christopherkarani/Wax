import Foundation

public struct ExtractiveSurrogateGenerator: HierarchicalSurrogateGenerator, Sendable, Equatable {
    public var algorithmID: String { "extractive_v1" }

    public init() {}

    public func generateSurrogate(sourceText: String, maxTokens: Int) async throws -> String {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxTokens > 0 else { return "" }

        let normalized = normalizeWhitespace(trimmed)
        let candidates = segment(text: normalized)
        if candidates.isEmpty {
            return try await truncateToTokens(normalized, maxTokens: maxTokens)
        }

        let scored = candidates.map { Candidate(text: $0, tokens: tokenSet(for: $0), score: score(sentence: $0)) }
        let selected = selectMMR(candidates: scored, maxItems: 8)
        let joined = selected.map(\.text).joined(separator: "\n")
        return try await truncateToTokens(joined, maxTokens: maxTokens)
    }
    
    // MARK: - Hierarchical Generation (Optimized)
    
    /// Optimized hierarchical generation: score once, select different amounts per tier.
    public func generateTiers(
        sourceText: String,
        config: SurrogateTierConfig
    ) async throws -> SurrogateTiers {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SurrogateTiers(full: "", gist: "", micro: "")
        }
        
        let normalized = normalizeWhitespace(trimmed)
        let segments = segment(text: normalized)
        
        // Handle case with no segments (single block of text)
        if segments.isEmpty {
            let full = try await truncateToTokens(normalized, maxTokens: config.fullMaxTokens)
            let gist = try await truncateToTokens(normalized, maxTokens: config.gistMaxTokens)
            let micro = try await truncateToTokens(normalized, maxTokens: config.microMaxTokens)
            return SurrogateTiers(full: full, gist: gist, micro: micro)
        }
        
        // Score all candidates once
        let scored = segments.map { 
            Candidate(text: $0, tokens: tokenSet(for: $0), score: score(sentence: $0)) 
        }
        
        // Select different amounts for each tier using MMR
        // Full: more items for higher fidelity
        // Gist: moderate items
        // Micro: minimal items (1-2 most important)
        let fullSelected = selectMMR(candidates: scored, maxItems: 8)
        let gistSelected = selectMMR(candidates: scored, maxItems: 3)
        let microSelected = selectMMR(candidates: scored, maxItems: 1)
        
        // Reorder by original position for coherence
        let fullOrdered = reorderByOriginalPosition(fullSelected, original: segments)
        let gistOrdered = reorderByOriginalPosition(gistSelected, original: segments)
        let microOrdered = reorderByOriginalPosition(microSelected, original: segments)
        
        // Join and truncate to token budgets
        let full = try await truncateToTokens(
            fullOrdered.joined(separator: "\n"),
            maxTokens: config.fullMaxTokens
        )
        let gist = try await truncateToTokens(
            gistOrdered.joined(separator: " "),
            maxTokens: config.gistMaxTokens
        )
        let micro = try await truncateToTokens(
            microOrdered.joined(separator: " "),
            maxTokens: config.microMaxTokens
        )
        
        return SurrogateTiers(full: full, gist: gist, micro: micro)
    }
    
    /// Reorder selected candidates to match their original order in the source text.
    private func reorderByOriginalPosition(_ selected: [Candidate], original: [String]) -> [String] {
        let positionMap = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element, $0.offset) })
        return selected
            .sorted { (positionMap[$0.text] ?? Int.max) < (positionMap[$1.text] ?? Int.max) }
            .map(\.text)
    }

    // MARK: - Scoring

    private struct Candidate: Sendable, Equatable {
        var text: String
        var tokens: Set<String>
        var score: Float
    }

    private func score(sentence: String) -> Float {
        let lower = sentence.lowercased()
        let wordCount = tokenize(lower).count
        if wordCount == 0 { return 0 }

        var score = Float(min(wordCount, 40))
        if wordCount < 4 { score *= 0.25 }
        if wordCount > 80 { score *= 0.7 }

        if lower.rangeOfCharacter(from: .decimalDigits) != nil { score += 6 }
        if sentence.contains(":") { score += 4 }
        if sentence.hasPrefix("-") || sentence.hasPrefix("*") { score += 2 }
        if sentence.contains("`") { score += 2 }

        let unique = Set(tokenize(lower)).count
        if wordCount > 0 {
            score += Float(unique) / Float(wordCount) * 3
        }

        return score
    }

    private func selectMMR(candidates: [Candidate], maxItems: Int) -> [Candidate] {
        guard maxItems > 0 else { return [] }
        var remaining = candidates.sorted { $0.score > $1.score }
        var selected: [Candidate] = []
        selected.reserveCapacity(min(maxItems, remaining.count))

        while selected.count < maxItems, !remaining.isEmpty {
            if selected.isEmpty {
                selected.append(remaining.removeFirst())
                continue
            }

            var bestIndex = 0
            var bestValue: Float = -.infinity

            for (idx, candidate) in remaining.enumerated() {
                let redundancy = selected
                    .map { jaccardSimilarity(candidate.tokens, $0.tokens) }
                    .max() ?? 0
                let value = candidate.score * (1 - redundancy)
                if value > bestValue {
                    bestValue = value
                    bestIndex = idx
                }
            }

            selected.append(remaining.remove(at: bestIndex))
        }

        return selected
    }

    private func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Float {
        if a.isEmpty || b.isEmpty { return 0 }
        let intersection = a.intersection(b).count
        if intersection == 0 { return 0 }
        let union = a.count + b.count - intersection
        guard union > 0 else { return 0 }
        return Float(intersection) / Float(union)
    }

    // MARK: - Tokenization & segmentation

    private func normalizeWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for ch in text {
            if ch.isWhitespace {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            lastWasSpace = false
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func segment(text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var segments: [String] = []
        segments.reserveCapacity(16)

        var start = text.startIndex
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            let isBoundary = ch == "." || ch == "!" || ch == "?" || ch == "\n" || ch == ";"
            if isBoundary {
                let end = text.index(after: idx)
                let slice = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !slice.isEmpty {
                    segments.append(slice)
                }
                start = end
            }
            idx = text.index(after: idx)
        }

        let tail = text[start..<text.endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            segments.append(tail)
        }

        return segments
    }

    private func tokenSet(for text: String) -> Set<String> {
        Set(tokenize(text.lowercased()))
    }

    private func tokenize(_ text: String) -> [String] {
        let parts = text.split { ch in
            !(ch.isLetter || ch.isNumber)
        }
        return parts
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private func truncateToTokens(_ text: String, maxTokens: Int) async throws -> String {
        let counter = try await TokenCounter.shared()
        return await counter.truncate(text, maxTokens: maxTokens)
    }
}
