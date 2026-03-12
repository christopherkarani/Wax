/// Heuristic query classifier for adaptive fusion (v1).
///
/// This is intentionally deterministic and offline:
/// - no Foundation Models
/// - no network calls
/// - no model downloads
package enum RuleBasedQueryClassifier {
    package static func classify(_ query: String) -> QueryType {
        let q = query.lowercased()

        if q.contains("when")
            || q.contains("yesterday")
            || q.contains("today")
            || q.contains("last ")
            || q.contains("recent")
            || q.contains("latest")
            || q.contains("before ")
            || q.contains("after ")
            || q.contains("between ") {
            return .temporal
        }

        if q.hasPrefix("what is")
            || q.hasPrefix("what are")
            || q.hasPrefix("who is")
            || q.hasPrefix("who are")
            || q.contains("define ")
            || q.contains("definition of")
            || q.contains("meaning of") {
            return .factual
        }

        if q.contains("how ")
            || q.contains("why ")
            || q.contains("explain")
            || q.contains("describe")
            || q.contains("relate") {
            return .semantic
        }

        return .exploratory
    }
}

