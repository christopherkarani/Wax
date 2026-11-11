import Foundation
import WaxCore
import WaxVectorSearch

/// Picks the built-in embedder that an automatic open loads for a store.
///
/// A store with no vectors gets the requested new-store built-in (e5 for `Memory`). A store
/// keeps the built-in that wrote its vectors, so a default never strands a MiniLM, e5 or
/// Arctic store.
package enum AutomaticEmbedderChoice {
    /// Tried in this order when matching a store's binding; the first compatible one wins.
    private static let bindingOrder: [BuiltInEmbeddingProvider] = [.miniLM, .e5, .arctic]

    /// - Parameters:
    ///   - binding: the store's recorded embedder, or `nil` for a new or legacy store.
    ///   - storeHasVectors: whether the store already holds vectors.
    ///   - newStore: the built-in to load for a store without vectors or a binding.
    ///   - available: the built-ins in this build, with the identity each records.
    package static func provider(
        binding: MemoryBinding?,
        storeHasVectors: Bool,
        newStore: BuiltInEmbeddingProvider,
        available: [BuiltInEmbeddingProvider: EmbeddingIdentity]
    ) -> BuiltInEmbeddingProvider {
        let fallback = available[newStore] != nil ? newStore : .miniLM
        guard let binding, !binding.isEmpty else {
            // Vectors without a binding predate bindings, and only MiniLM wrote stores then.
            // Without MiniLM in the build this reports unavailable rather than attaching
            // another model to MiniLM vectors.
            return storeHasVectors ? .miniLM : fallback
        }
        for provider in bindingOrder {
            guard let identity = available[provider] else { continue }
            let verdict = MemoryBindingCompatibility.verdict(
                binding: binding,
                storeHasVectors: storeHasVectors,
                identity: identity
            )
            if case .incompatible = verdict { continue }
            return provider
        }
        // No built-in matches; the fallback reports the mismatch as unavailable.
        return fallback
    }
}
