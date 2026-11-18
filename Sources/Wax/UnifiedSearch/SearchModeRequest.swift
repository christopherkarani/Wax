import Foundation
import WaxVectorSearch

/// A requested ``SearchMode`` whose hybrid text weight the caller may leave to the store.
///
/// `hybrid(alpha: nil)` means no weight was chosen: the store searching resolves it to the
/// ``HybridTextWeight`` default for the embedder serving it.
/// Broker, MCP, CLI, and `Memory.search` requests carry this until a store resolves it.
package enum SearchModeRequest: Sendable, Equatable {
    case textOnly
    case vectorOnly
    /// `nil`: the store's default text weight. A value is the caller's choice and is used as given.
    case hybrid(alpha: Float? = nil)

    /// The caller chose `mode`, including any hybrid weight it carries.
    package init(_ mode: SearchMode) {
        switch mode {
        case .textOnly:
            self = .textOnly
        case .vectorOnly:
            self = .vectorOnly
        case .hybrid(let alpha):
            self = .hybrid(alpha: alpha)
        }
    }

    /// The mode to run, with an unchosen hybrid weight replaced by `defaultHybridAlpha`.
    package func resolved(defaultHybridAlpha: Float) -> SearchMode {
        switch self {
        case .textOnly:
            .textOnly
        case .vectorOnly:
            .vectorOnly
        case .hybrid(let alpha):
            .hybrid(alpha: alpha ?? defaultHybridAlpha)
        }
    }
}

/// Text weight (alpha) a hybrid search uses when the caller chose none.
///
/// e5-small-v2 retrieves best with text weighted 0.4 (LongMemEval R_all@5 0.905 against
/// 0.893 at 0.5; LoCoMo 0.555 against 0.545). Every other embedder keeps 0.5.
package enum HybridTextWeight {
    /// Default for every store not served by e5-small-v2.
    package static let standard: Float = 0.5
    /// Default for stores served by the built-in e5-small-v2 embedder.
    package static let e5: Float = 0.4

    /// The identity the built-in e5 embedder records (`E5Embedder.bindingIdentity`, which the
    /// `Wax` target cannot name when the `E5Embeddings` trait is off).
    private static let e5Provider = "Wax"
    private static let e5Model = "E5SmallV2-prefixed"

    /// Default weight for a store whose vectors come from the embedder with `identity`.
    package static func storeDefault(for identity: EmbeddingIdentity?) -> Float {
        guard let identity, identity.provider == e5Provider, identity.model == e5Model else {
            return standard
        }
        return e5
    }

    /// Default weight for a store that will be served by the built-in `provider`.
    package static func storeDefault(for provider: BuiltInEmbeddingProvider?) -> Float {
        provider == .e5 ? e5 : standard
    }
}
