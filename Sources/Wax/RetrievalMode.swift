/// Retrieval mode for `Memory.search` / `MemoryOrchestrator` recall.
///
/// Apps keep writing `Memory.RetrievalMode`. The enum lives at module scope so
/// the package engine does not take a type nested on the public facade.
public enum RetrievalMode: Sendable, Equatable {
    /// Search only the full-text index.
    case textOnly
    /// Search only the vector index. Requires vector search and an embedding provider.
    case vectorOnly
    /// Blend full-text and vector results using Reciprocal Rank Fusion.
    ///
    /// The alpha value is clamped by Wax's search engine. Higher values favor
    /// text results; lower values favor vector results.
    case hybrid(alpha: Float = 0.5)
}
