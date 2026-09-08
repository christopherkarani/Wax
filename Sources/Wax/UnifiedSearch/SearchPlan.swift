/// Pure pre-I/O description of which lanes and windows a `SearchRequest` will use.
package struct SearchPlan: Sendable, Equatable {
    package var trimmedQuery: String?
    package var queryType: QueryType
    package var weights: FusionWeights
    package var includeText: Bool
    package var includeVector: Bool
    package var exactIntentWindow: Int?
    package var candidateLimit: Int
    package var matchPlan: MatchPlan?
}

package extension SearchPlan {
    static func make(_ request: SearchRequest) -> SearchPlan {
        let trimmedQuery = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let queryType: QueryType
        if let trimmedQuery, !trimmedQuery.isEmpty {
            queryType = RuleBasedQueryClassifier.classify(trimmedQuery)
        } else {
            queryType = .exploratory
        }

        let includeText: Bool
        let includeVector: Bool
        switch request.mode {
        case .textOnly:
            includeText = true
            includeVector = false
        case .vectorOnly:
            includeText = false
            includeVector = true
        case .hybrid:
            includeText = true
            includeVector = true
        }

        let requestedTopK = max(0, request.topK)
        // Exact-intent overfetch + rerank are text-lane only. vectorOnly must not
        // widen the pending window or promote a buried lexical frame.
        let exactIntentWindow: Int? = (
            includeText && (trimmedQuery.map(RuleBasedQueryClassifier.isExactIntentQuery) ?? false)
        ) ? min(max(boundedMultiply(requestedTopK, by: 3), 12), 48) : nil

        let matchPlan: MatchPlan?
        if let trimmedQuery, !trimmedQuery.isEmpty {
            matchPlan = MatchPlan.plan(query: trimmedQuery)
        } else {
            matchPlan = nil
        }

        return SearchPlan(
            trimmedQuery: trimmedQuery,
            queryType: queryType,
            weights: AdaptiveFusionConfig.default.weights(for: queryType),
            includeText: includeText,
            includeVector: includeVector,
            exactIntentWindow: exactIntentWindow,
            candidateLimit: candidateLimit(
                for: requestedTopK,
                filter: request.frameFilter ?? FrameFilter()
            ),
            matchPlan: matchPlan
        )
    }

    /// Overflow-safe `value * multiplier` used for overfetch and rerank windows.
    static func boundedMultiply(_ value: Int, by multiplier: Int) -> Int {
        guard value > 0, multiplier > 0 else { return 0 }
        guard value <= Int.max / multiplier else { return Int.max }
        return value * multiplier
    }

    private static func candidateLimit(for topK: Int) -> Int {
        guard topK > 0 else { return 0 }
        let expanded = boundedMultiply(topK, by: 3)
        let capped = min(expanded, 1000)
        // Keep the public request's topK from becoming an unbounded SQLite or
        // vector-engine limit. FTS independently caps at 10,000; matching the
        // same ceiling here also makes Int.max requests safe.
        return min(max(topK, capped), 10_000)
    }

    private static func candidateLimit(for topK: Int, filter: FrameFilter) -> Int {
        let baseLimit = candidateLimit(for: topK)
        guard needsCallerFilterOverfetch(filter) else { return baseLimit }

        let multiplied = boundedMultiply(topK, by: 5)
        let withSlack = topK > Int.max - 200 ? Int.max : topK + 200
        let overfetchLimit = min(1000, max(multiplied, withSlack))
        return max(baseLimit, overfetchLimit)
    }

    private static func needsCallerFilterOverfetch(_ filter: FrameFilter) -> Bool {
        if filter.frameIds != nil { return true }
        guard let metadataFilter = filter.metadataFilter else { return false }
        return !metadataFilter.requiredEntries.isEmpty
            || !metadataFilter.requiredTags.isEmpty
            || !metadataFilter.requiredLabels.isEmpty
    }
}
