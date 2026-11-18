import Foundation
import WaxCore
import WaxVectorSearch

/// Picks the built-in that `--embedder auto` gives new stores in the CLI, MCP server and broker.
///
/// These hosts recall across several stores at once (the durable store, live and ended session
/// stores, the corpus store) and merge the hits by score. Scores from different embedders are
/// not comparable, so every store one host serves must share an embedder. A fresh install gets
/// e5; once any served store is bound to MiniLM, new stores follow it. Existing stores keep
/// the built-in that wrote them either way (``AutomaticEmbedderChoice``).
package enum HostNewStoreEmbedder {
    /// `true` for the choice that defers to the stores on disk rather than naming a built-in.
    package static func isAutomatic(_ embedderChoice: String) -> Bool {
        let choice = embedderChoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return choice.isEmpty || choice == "auto"
    }

    /// Reads each store's committed binding, stopping at the first one bound to MiniLM.
    package static func provider(
        servedStores: [URL],
        available: [BuiltInEmbeddingProvider: EmbeddingIdentity] = BuiltInEmbeddingCompiler.bindingIdentities()
    ) -> BuiltInEmbeddingProvider {
        provider(states: servedStores.lazy.map(committedState(at:)), available: available)
    }

    /// - Parameters:
    ///   - states: each served store's last commit, or `nil` for a missing or unreadable store.
    ///   - available: the built-ins in this build, with the identity each records.
    package static func provider(
        states: some Sequence<CommittedEmbeddingState?>,
        available: [BuiltInEmbeddingProvider: EmbeddingIdentity]
    ) -> BuiltInEmbeddingProvider {
        guard available[.e5] != nil else { return .miniLM }
        // Without MiniLM in the build a MiniLM store gets no vector search, so nothing to match.
        guard let miniLM = available[.miniLM] else { return .e5 }
        for case let state? in states where isBoundToMiniLM(state, miniLM: miniLM) {
            return .miniLM
        }
        return .e5
    }

    private static func isBoundToMiniLM(_ state: CommittedEmbeddingState, miniLM: EmbeddingIdentity) -> Bool {
        let hasVectors = state.vectorCount > 0
        guard let binding = state.binding, !binding.isEmpty else {
            // Vectors without a binding predate bindings, and only MiniLM wrote stores then.
            return hasVectors
        }
        let verdict = MemoryBindingCompatibility.verdict(
            binding: binding,
            storeHasVectors: hasVectors,
            identity: miniLM
        )
        if case .incompatible = verdict { return false }
        return true
    }

    private static func committedState(at url: URL) -> CommittedEmbeddingState? {
        do {
            return try Wax.committedEmbeddingState(at: url)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "host new-store embedder probe",
                fallback: "store treated as unbound"
            )
            return nil
        }
    }
}
