/// Search mode for unified search and `Memory.search` / `MemoryOrchestrator` recall.
///
/// Apps keep writing ``Memory/RetrievalMode``, a public typealias of this type.
///
/// - `.hybrid(alpha:)` controls the text vs vector weighting in fusion.
///   The alpha value is clamped by Wax's search engine. Higher values favor
///   text results; lower values favor vector results.
/// - Query-aware weights from `AdaptiveFusionConfig` may further scale the effective weights.
public enum SearchMode: Sendable, Equatable, CustomStringConvertible {
    /// Search only the full-text index.
    case textOnly
    /// Search only the vector index. Requires vector search and an embedding provider.
    case vectorOnly
    /// Blend full-text and vector results using Reciprocal Rank Fusion (0 = all vector, 1 = all text).
    case hybrid(alpha: Float = 0.5)

    /// Stable diagnostics / MCP / docs string: `"text"`, `"vector"`, or `"hybrid(alpha=0.500)"`.
    public var diagnosticsSummary: String {
        switch self {
        case .textOnly:
            return "text"
        case .vectorOnly:
            return "vector"
        case .hybrid(let alpha):
            let clamped = Self.clampHybridAlpha(alpha)
            return "hybrid(alpha=\(String(format: "%.3f", Double(clamped))))"
        }
    }

    public var description: String { diagnosticsSummary }

    /// Clamp hybrid alpha the same way search and diagnostics formatting do.
    public static func clampHybridAlpha(_ alpha: Float) -> Float {
        guard alpha.isFinite else { return 0.5 }
        return min(1, max(0, alpha))
    }
}
