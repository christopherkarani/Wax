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

    /// `true` only when a provider can embed queries and new saves.
    public var isQueryEmbedderConfigured: Bool {
        switch self {
        case .active, .degraded:
            true
        case .disabled, .loading, .unavailable:
            false
        }
    }

    /// Identity carried by ``active`` or ``degraded``, if any.
    public var identity: EmbeddingIdentity? {
        switch self {
        case .active(let identity):
            identity
        case .degraded(let identity, _):
            identity
        case .disabled, .loading, .unavailable:
            nil
        }
    }

    package var wireName: String {
        switch self {
        case .disabled:
            "disabled"
        case .loading:
            "loading"
        case .active:
            "active"
        case .degraded:
            "degraded"
        case .unavailable:
            "unavailable"
        }
    }

    package var wireReason: String? {
        switch self {
        case .degraded(_, let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "unspecified" : trimmed
        case .unavailable(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "unspecified" : trimmed
        case .disabled, .loading, .active:
            return nil
        }
    }
}
