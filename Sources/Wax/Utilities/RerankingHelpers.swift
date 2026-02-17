import Foundation

/// Shared text-matching helpers used by both `FastRAGContextBuilder.rerankCandidatesForAnswer`
/// and `UnifiedSearch.intentAwareRerank`. Scoring weights are intentionally different between
/// the two rerankers; only stateless text predicates belong here.
enum RerankingHelpers {

    /// True when the text contains language indicating a tentative / unconfirmed launch date.
    /// Used to penalize results that match date-intent queries but carry low-confidence dates.
    static func containsTentativeLaunchLanguage(_ text: String) -> Bool {
        text.contains("tentative")
            || text.contains("draft")
            || text.contains("proposed")
            || text.contains("pending approval")
            || text.contains("target is")
            || text.contains("target date")
            || text.contains("could be")
            || text.contains("estimate")
    }
}
