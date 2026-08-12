import Foundation

/// Setup status of the embedding provider wired into a ``Memory`` store.
///
/// This is populated at initialization. Per-query lane execution continues to
/// be reported on ``RAGContext/diagnostics``.
public enum EmbeddingStatus: Sendable, Equatable {
    /// Vector search is disabled, so no embedding provider is used.
    case disabled
    /// An embedding provider is active. `identity` is the provider's advertised identity.
    case active(identity: EmbeddingIdentity?)
    /// Automatic setup was attempted and failed; the store fell back to text-only search.
    case unavailable(reason: String)
}
