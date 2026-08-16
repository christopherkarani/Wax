import Foundation

/// Shared explanation-list dedupe for search/orchestrator result assembly.
enum SearchExplanationDeduper {
    static func dedupedExplanations(_ reasons: [String]) -> [String] {
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
}
