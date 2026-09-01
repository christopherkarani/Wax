import Foundation

/// Pure rerank transforms over fused unified-search hits.
///
/// Ranking owns the published `score`. Recall assembly may reorder later
/// but must not rewrite these values.
package enum UnifiedRanking {
    package static func semanticMemoryRerank(
        results: [SearchResponse.Result],
        scopeContext: MemoryScopeContext?,
        nowMs: Int64,
        maxWindow: Int
    ) -> [SearchResponse.Result] {
        let cappedWindow = min(max(0, maxWindow), results.count)
        guard cappedWindow > 0 else { return results }

        let scoredHead = results.prefix(cappedWindow).enumerated().compactMap { index, result -> (index: Int, composite: Float, adjustment: Float, result: SearchResponse.Result)? in
            let semantic = MemorySemantics.rankingReasons(
                metadata: result.metadata,
                scope: scopeContext,
                nowMs: nowMs
            )
            guard semantic.adjustment > -9.5 else { return nil }
            var updated = result
            if !semantic.reasons.isEmpty {
                updated.explanations = dedupedExplanations(result.explanations + semantic.reasons)
            }
            return (index: index, composite: result.score + semantic.adjustment, adjustment: semantic.adjustment, result: updated)
        }

        guard !scoredHead.isEmpty else { return Array(results.dropFirst(cappedWindow)) }
        let meaningfulAdjustmentExists = scoredHead.contains { abs($0.adjustment) >= 0.11 }
        guard meaningfulAdjustmentExists else {
            let retained = scoredHead.sorted { $0.index < $1.index }.map(\.result)
            if cappedWindow == results.count {
                return retained
            }
            var combined = retained
            combined.reserveCapacity(results.count)
            combined.append(contentsOf: results.dropFirst(cappedWindow).filter {
                !MemorySemantics.parse(metadata: $0.metadata, nowMs: nowMs).isExpired
            })
            return combined
        }

        let rankedHead = scoredHead.sorted { lhs, rhs in
            if lhs.composite != rhs.composite { return lhs.composite > rhs.composite }
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            return lhs.index < rhs.index
        }.map { item -> SearchResponse.Result in
            var result = item.result
            result.score = item.composite
            return result
        }

        if cappedWindow == results.count {
            return rankedHead
        }
        var combined = rankedHead
        combined.reserveCapacity(results.count)
        combined.append(contentsOf: results.dropFirst(cappedWindow).filter {
            !MemorySemantics.parse(metadata: $0.metadata, nowMs: nowMs).isExpired
        })
        return combined
    }

    package static func intentAwareRerank(
        results: [SearchResponse.Result],
        query: String,
        maxWindow: Int,
        analyzer: QueryAnalyzer = QueryAnalyzer()
    ) -> [SearchResponse.Result] {
        let cappedWindow = min(max(0, maxWindow), results.count)
        guard cappedWindow > 1 else { return results }

        let intents = analyzer.detectIntent(query: query)
        let queryTerms = Set(analyzer.normalizedTerms(query: query))
        let queryEntities = analyzer.entityTerms(query: query)
        let queryYears = analyzer.yearTerms(in: query)
        let queryDateKeys = analyzer.normalizedDateKeys(in: query)
        let rawPhrases = MatchPlan.rawQuotedPhrases(from: query)
        let lowerRawPhrases = rawPhrases.map { $0.lowercased() }
        let normalizedPhrases = MatchPlan.normalizedQuotedPhrases(from: query)
        let queryNumericEntities = queryEntities.filter { termContainsDigits($0) }
        let queryAlphaEntities = queryEntities.filter { isLettersOnly($0) }
        let queryNumericTerms = queryTerms.filter { isDigitsOnly($0) }
        let hasTargetIntent =
            intents.contains(.asksLocation)
            || intents.contains(.asksDate)
            || intents.contains(.asksOwnership)

        let hasDisambiguationSignals =
            !queryEntities.isEmpty
            || !queryYears.isEmpty
            || !queryDateKeys.isEmpty
            || !rawPhrases.isEmpty
            || !normalizedPhrases.isEmpty

        if !hasTargetIntent || !hasDisambiguationSignals {
            return results
        }

        // Ranking owns the published score. Recall assembly may reorder later
        // but must not rewrite these values.
        func compositeScore(for result: SearchResponse.Result) -> Float {
            var total = result.score
            guard let preview = result.previewText, !preview.isEmpty else { return total }

            let comparablePreview = dehighlightedPreviewText(preview)
            let previewTerms = Set(analyzer.normalizedTerms(query: comparablePreview))
            let previewEntities = analyzer.entityTerms(query: comparablePreview)
            let previewYears = analyzer.yearTerms(in: comparablePreview)
            let previewDateKeys = analyzer.normalizedDateKeys(in: comparablePreview)
            let previewAlphaEntities = previewEntities.filter { isLettersOnly($0) }
            let lower = comparablePreview.lowercased()
            let normalizedLower = normalizedPhraseComparableText(comparablePreview)
            let vectorInfluenced = result.sources.contains(.vector)

            if !queryTerms.isEmpty, !previewTerms.isEmpty {
                let overlap = Float(queryTerms.intersection(previewTerms).count)
                let recall = overlap / Float(max(1, queryTerms.count))
                let precision = overlap / Float(max(1, previewTerms.count))
                total += recall * 0.55   // Lower than FastRAG: false positives more visible in search UI
                total += precision * 0.25
            }

            if !queryEntities.isEmpty {
                let entityHits = queryEntities.intersection(previewEntities).count
                let coverage = Float(entityHits) / Float(max(1, queryEntities.count))
                if !queryNumericEntities.isEmpty {
                    let numericHits = queryNumericEntities.intersection(previewEntities).count
                    let numericCoverage = Float(numericHits) / Float(max(1, queryNumericEntities.count))
                    total += numericCoverage * 1.95
                }
                if !queryAlphaEntities.isEmpty {
                    let alphaHits = queryAlphaEntities.intersection(previewAlphaEntities).count
                    let alphaCoverage = Float(alphaHits) / Float(max(1, queryAlphaEntities.count))
                    total += alphaCoverage * 1.25
                }
                total += coverage * 0.30
                if entityHits == 0 {
                    total -= !queryNumericEntities.isEmpty ? 0.85 : 0.45
                    if !queryNumericTerms.isEmpty,
                       !queryNumericTerms.intersection(previewTerms).isEmpty {
                        total -= 0.75
                    }
                }
                if !queryAlphaEntities.isEmpty,
                   queryAlphaEntities.intersection(previewAlphaEntities).isEmpty,
                   !previewAlphaEntities.isEmpty {
                    total -= 0.40
                }
            }

            if !queryYears.isEmpty {
                let yearHits = queryYears.intersection(previewYears).count
                let yearCoverage = Float(yearHits) / Float(max(1, queryYears.count))
                total += yearCoverage * 1.25
                if yearHits == 0, !previewYears.isEmpty {
                    total -= 1.10
                }
            }

            if !queryDateKeys.isEmpty {
                let dateHits = queryDateKeys.intersection(previewDateKeys).count
                let dateCoverage = Float(dateHits) / Float(max(1, queryDateKeys.count))
                total += dateCoverage * 1.15
                if dateHits == 0, !previewDateKeys.isEmpty {
                    total -= 0.95
                }
            }

            let strictRawPhrases = lowerRawPhrases.filter { phrase in
                phrase.contains("-") || phrase.split(whereSeparator: \.isWhitespace).count >= 2
            }
            var exactPhraseHits = 0
            var strictExactHits = 0
            if !lowerRawPhrases.isEmpty {
                for phrase in lowerRawPhrases where lower.contains(phrase) {
                    exactPhraseHits += 1
                }
                for phrase in strictRawPhrases where lower.contains(phrase) {
                    strictExactHits += 1
                }
                let strictPhraseIntent = !strictRawPhrases.isEmpty
                if exactPhraseHits > 0 {
                    total += Float(exactPhraseHits) * (strictPhraseIntent ? 2.10 : 1.20)
                } else {
                    total -= strictPhraseIntent ? 1.40 : 0.35
                }
                let strictMisses = strictRawPhrases.count - strictExactHits
                if strictMisses > 0 {
                    total -= Float(strictMisses) * 0.85
                }
            }

            if !normalizedPhrases.isEmpty {
                var normalizedHits = 0
                for phrase in normalizedPhrases where normalizedLower.contains(phrase) {
                    normalizedHits += 1
                }
                let coverage = Float(normalizedHits) / Float(max(1, normalizedPhrases.count))
                let strictPhraseMiss = !strictRawPhrases.isEmpty && strictExactHits == 0
                total += coverage * (strictPhraseMiss ? 0.20 : 0.75)
                if strictPhraseMiss {
                    total -= 0.55
                }
                if normalizedHits == 0 {
                    total -= strictPhraseMiss ? 0.45 : 0.20
                }
            }

            if intents.contains(.asksLocation) {
                if containsMovedToLocationPattern(comparablePreview) {
                    total += 1.60
                } else if lower.contains("moved to") || lower.contains("move to") {
                    total += 0.45
                } else if lower.contains("city") {
                    total += 0.10
                }
                if lower.contains("without a destination")
                    || lower.contains("city move")
                    || lower.contains("retrospective")
                {
                    total -= 0.75
                }
                if lower.contains("allergic") || lower.contains("health") || lower.contains("peanut") {
                    total -= 1.10
                }
                if lower.contains("prefers") || lower.contains("prefer") {
                    total -= 0.55
                }
            }

            if intents.contains(.asksDate) {
                let tentative = RerankingHelpers.containsTentativeLaunchLanguage(lower)
                if lower.contains("public launch is"), !tentative {
                    total += 1.70
                } else if lower.contains("public launch") || analyzer.containsDateLiteral(comparablePreview) {
                    total += 1.20
                }
                if tentative {
                    let scaledPenalty = max(
                        vectorInfluenced ? 2.90 : 2.45,
                        result.score * (vectorInfluenced ? 1.60 : 1.40)
                    )
                    total -= scaledPenalty
                }
                if lower.contains("draft memo") {
                    total -= vectorInfluenced ? 1.45 : 1.20
                }
                if lower.contains(" owns ") || lower.contains("owner") || lower.contains("deployment readiness") {
                    total -= 0.40
                }
            }

            if intents.contains(.asksOwnership) {
                if lower.contains(" owns ")
                    || lower.contains("owner")
                    || lower.contains("owns deployment readiness")
                {
                    total += 1.10
                }
                if lower.contains("public launch") && !lower.contains(" owns ") {
                    total -= 0.35
                }
            }

            if looksDistractorLike(lower) {
                total -= 0.40
            }

            return total
        }

        var scoredHead: [(index: Int, score: Float)] = []
        scoredHead.reserveCapacity(cappedWindow)
        for index in 0..<cappedWindow {
            let result = results[index]
            scoredHead.append((index: index, score: compositeScore(for: result)))
        }
        scoredHead.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsResult = results[lhs.index]
            let rhsResult = results[rhs.index]
            if lhsResult.score != rhsResult.score { return lhsResult.score > rhsResult.score }
            return lhsResult.frameId < rhsResult.frameId
        }

        var rerankedHead: [SearchResponse.Result] = []
        rerankedHead.reserveCapacity(cappedWindow)
        for (rank, candidate) in scoredHead.enumerated() {
            var result = results[candidate.index]
            result.score = candidate.score
            if var diagnostics = result.rankingDiagnostics {
                diagnostics.tieBreakReason = rank == 0 ? .topResult : .rerankComposite
                result.rankingDiagnostics = diagnostics
            }
            rerankedHead.append(result)
        }

        if cappedWindow == results.count {
            return rerankedHead
        }
        var combined = rerankedHead
        combined.reserveCapacity(results.count)
        combined.append(contentsOf: results.dropFirst(cappedWindow))
        return combined
    }

    /// Query-side exact-intent boost for identifiers and quoted phrases.
    /// FTS `unicode61` splits identifier punctuation, so similar prose can beat a
    /// unique token on BM25; same-repo/project semantic rerank can then lift a
    /// neighbor. A token-boundary match receives the strong bonus, while a
    /// substring match receives only a small lexical nudge. This pass runs after
    /// semantic rerank so an exact phrase hit stays rank 1. Vector-only ranking
    /// is unchanged.
    package static func identifierExactMatchRerank(
        results: [SearchResponse.Result],
        query: String,
        maxWindow: Int
    ) -> [SearchResponse.Result] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return results }
        let cappedWindow = min(max(0, maxWindow), results.count)
        guard cappedWindow > 0 else { return results }

        let needles = exactIntentNeedles(from: needle)
        guard !needles.isEmpty else { return results }

        // Larger than same-repo (0.9) + same-project (0.7) + decision (0.45) + durable (0.25).
        let exactTokenBonus: Float = 5.0
        let substringBonus: Float = 0.5

        let scoredHead = results.prefix(cappedWindow).enumerated().map { index, result -> (index: Int, composite: Float, strength: ExactIntentMatchStrength, result: SearchResponse.Result) in
            let haystack = dehighlightedPreviewText(result.previewText ?? "").lowercased()
            let strength = bestExactIntentMatch(in: haystack, needles: needles)
            var updated = result
            switch strength {
            case .token:
                updated.explanations = dedupedExplanations(result.explanations + ["exact identifier match"])
            case .substring:
                updated.explanations = dedupedExplanations(result.explanations + ["identifier substring match"])
            case .none:
                break
            }
            return (
                index: index,
                composite: result.score + strength.bonus(exactTokenBonus: exactTokenBonus, substringBonus: substringBonus),
                strength: strength,
                result: updated
            )
        }

        guard scoredHead.contains(where: { $0.strength != .none }) else { return results }

        let rankedHead = scoredHead.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength.rawValue > rhs.strength.rawValue }
            if lhs.composite != rhs.composite { return lhs.composite > rhs.composite }
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            return lhs.index < rhs.index
        }.map { item -> SearchResponse.Result in
            var result = item.result
            result.score = item.composite
            return result
        }

        if cappedWindow == results.count {
            return rankedHead
        }
        var combined = rankedHead
        combined.reserveCapacity(results.count)
        combined.append(contentsOf: results.dropFirst(cappedWindow))
        return combined
    }

    package static func dedupedExplanations(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(reasons.count)
        for reason in reasons {
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    /// Quoted phrases carry the exact target inside a natural-language query;
    /// identifier queries use the whole trimmed value. Preserve all quoted
    /// phrases so a result matching any explicit target can be promoted.
    private static func exactIntentNeedles(from query: String) -> [String] {
        let phrases = MatchPlan.rawQuotedPhrases(from: query).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return phrases.isEmpty ? [query] : phrases
    }

    private static func bestExactIntentMatch(
        in haystack: String,
        needles: [String]
    ) -> ExactIntentMatchStrength {
        guard !haystack.isEmpty else { return .none }
        var best: ExactIntentMatchStrength = .none
        for needle in needles {
            let candidate = needle.lowercased()
            guard !candidate.isEmpty else { continue }
            let strength = exactIntentMatchStrength(needle: candidate, in: haystack)
            if strength.rawValue > best.rawValue {
                best = strength
                if best == .token { break }
            }
        }
        return best
    }

    /// Classify a case-insensitive occurrence by the characters immediately
    /// around it. Identifier glue is treated as part of the token when it
    /// continues into another identifier scalar, while hyphen/underscore glue
    /// remains strict for the #166 path. This preserves UUID/dot/path equality
    /// without making sentence punctuation defeat a quoted name.
    private static func exactIntentMatchStrength(
        needle: String,
        in haystack: String
    ) -> ExactIntentMatchStrength {
        let identifierGlue = CharacterSet(charactersIn: "-_.:/@#%+")
        var searchStart = haystack.startIndex
        var best: ExactIntentMatchStrength = .none

        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, options: [.literal], range: searchStart..<haystack.endIndex)
        {
            let before = range.lowerBound > haystack.startIndex
                ? haystack.index(before: range.lowerBound)
                : nil
            let after = range.upperBound < haystack.endIndex
                ? range.upperBound
                : nil
            let hasTokenBoundaries = isExactIntentBoundary(
                at: before,
                direction: .before,
                in: haystack,
                glue: identifierGlue
            ) && isExactIntentBoundary(
                at: after,
                direction: .after,
                in: haystack,
                glue: identifierGlue
            )
            if hasTokenBoundaries {
                return .token
            }
            best = .substring
            searchStart = range.upperBound
        }
        return best
    }

    private enum ExactIntentMatchStrength: Int, Equatable {
        case none = 0
        case substring = 1
        case token = 2

        func bonus(exactTokenBonus: Float, substringBonus: Float) -> Float {
            switch self {
            case .none: 0
            case .substring: substringBonus
            case .token: exactTokenBonus
            }
        }
    }

    private enum ExactIntentBoundaryDirection {
        case before
        case after
    }

    private static func isExactIntentBoundary(
        at index: String.Index?,
        direction: ExactIntentBoundaryDirection,
        in haystack: String,
        glue: CharacterSet
    ) -> Bool {
        guard let index else { return true }
        let character = haystack[index]
        let scalarView = character.unicodeScalars
        if scalarView.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) {
            return false
        }
        // Hyphen and underscore are always identifier glue. A quoted phrase
        // such as "Ada Lovelace" must not treat "Ada Lovelace-Foundation"
        // as an equal token sequence merely because the query itself has no
        // identifier punctuation.
        if scalarView.contains(where: { $0 == "-" || $0 == "_" }) {
            return false
        }
        guard scalarView.contains(where: glue.contains) else {
            return true
        }

        // Punctuation in an identifier can also be ordinary sentence
        // punctuation (for example, `build.agent_v2.`). Walk through a glue
        // run and only reject the boundary when it continues into another
        // identifier scalar. This keeps `build.agent_v2.extra` as a prefix
        // distractor while allowing a terminal period after the exact ID.
        var cursor: String.Index
        switch direction {
        case .before:
            guard index > haystack.startIndex else { return true }
            cursor = haystack.index(before: index)
        case .after:
            guard index < haystack.endIndex else { return true }
            cursor = haystack.index(after: index)
        }
        while cursor < haystack.endIndex {
            let adjacent = haystack[cursor]
            let adjacentScalars = adjacent.unicodeScalars
            if adjacentScalars.contains(where: {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }) {
                return false
            }
            guard adjacentScalars.contains(where: glue.contains) else {
                return true
            }
            switch direction {
            case .before:
                guard cursor > haystack.startIndex else { return true }
                cursor = haystack.index(before: cursor)
            case .after:
                cursor = haystack.index(after: cursor)
            }
        }
        return true
    }

    package static func dehighlightedPreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    /// UnifiedSearch distractor check — broader than FastRAGContextBuilder.looksDistractor.
    /// Includes "allergic", "draft memo", "tentative", "pending approval" because UnifiedSearch
    /// needs wider filtering for search result quality. Omits "no authoritative" (only relevant
    /// for answer-focused context assembly where confidence-undermining language matters).
    private static func looksDistractorLike(_ text: String) -> Bool {
        text.contains("weekly report")
            || text.contains("checklist")
            || text.contains("signoff")
            || text.contains("allergic")
            || text.contains("distractor")
            || text.contains("draft memo")
            || text.contains("tentative")
            || text.contains("pending approval")
    }

    private static let movedToLocationRegex = try? NSRegularExpression(
        pattern: #"\b(?:moved|move)\s+to\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b"#
    )

    private static func containsMovedToLocationPattern(_ text: String) -> Bool {
        guard let regex = movedToLocationRegex else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func isDigitsOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isLettersOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func termContainsDigits(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private static func normalizedPhraseComparableText(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .joined(separator: " ")
    }
}
