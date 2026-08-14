/// Runtime state of the embedding provider attached to a ``Memory`` store.
public enum EmbeddingStatus: Sendable, Equatable {
    /// Vector search was explicitly disabled.
    case disabled
    /// A provider is loading while text operations remain available.
    case loading
    /// Vector ingestion and query embedding are ready.
    case active(EmbeddingIdentity?)
    /// The provider is ready, but some previously saved text could not be backfilled.
    case degraded(EmbeddingIdentity?, reason: String)
    /// No provider could be activated.
    case unavailable(reason: String)
}
