/// Search mode for unified search.
///
/// v1 notes:
/// - `.hybrid(alpha:)` controls the text vs vector weighting in fusion.
/// - Query-aware weights from `AdaptiveFusionConfig` may further scale the effective weights.
package enum SearchMode: Sendable, Equatable {
    case textOnly
    case vectorOnly
    case hybrid(alpha: Float) // 0 = all vector, 1 = all text
}

