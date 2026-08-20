/// Retrieval mode for `Memory.search` / `MemoryOrchestrator` recall.
///
/// Apps keep writing `Memory.RetrievalMode`. The enum lives at module scope so
/// the package engine does not take a type nested on the public facade.
public enum RetrievalMode: Sendable, Equatable, CustomStringConvertible {
    /// Search only the full-text index.
    case textOnly
    /// Search only the vector index. Requires vector search and an embedding provider.
    case vectorOnly
    /// Blend full-text and vector results using Reciprocal Rank Fusion.
    ///
    /// The alpha value is clamped by Wax's search engine. Higher values favor
    /// text results; lower values favor vector results.
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

package extension RetrievalMode {
    init(_ mode: SearchMode) {
        switch mode {
        case .textOnly:
            self = .textOnly
        case .vectorOnly:
            self = .vectorOnly
        case .hybrid(let alpha):
            self = .hybrid(alpha: alpha)
        }
    }

    var searchMode: SearchMode {
        switch self {
        case .textOnly:
            .textOnly
        case .vectorOnly:
            .vectorOnly
        case .hybrid(let alpha):
            .hybrid(alpha: Self.clampHybridAlpha(alpha))
        }
    }
}
