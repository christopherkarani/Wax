import Foundation
import WaxCore
import WaxVectorSearch

enum MemoryBindingCompatibility {
    /// How a store's persisted binding relates to the embedder being attached.
    enum Verdict: Equatable, Sendable {
        case compatible
        /// Same provider, dimensions and normalization, but the stored vectors come from a
        /// superseded revision of the attached model. They are in a different vector space:
        /// serve text-only, re-embed every live frame, then swap the binding.
        case needsReembed(reason: String)
        /// Different model or vector shape; opening must fail as before.
        case incompatible(reason: String)
    }

    private static let modelAliases: [String: String] = [
        "minilmall": "minilm",
        "arctic": "arcticembeds",
    ]

    /// Canonical model -> canonical models whose vectors it replaces, and why.
    private static let supersededModels: [String: (replaces: Set<String>, reason: String)] = [
        // The pre-#257 MiniLM graph returned the BERT pooler (tanh(dense(CLS))) instead of
        // the sentence-transformers mean pooling, so those vectors are ~0 cosine to current queries.
        "minilmall-mean": (replaces: ["minilm"], reason: "vectors from superseded MiniLM revision"),
    ]

    static func binding(from identity: EmbeddingIdentity) -> MemoryBinding {
        MemoryBinding(
            embeddingProvider: identity.provider,
            embeddingModel: identity.model,
            embeddingDimensions: identity.dimensions.map(UInt32.init),
            embeddingNormalized: identity.normalized
        )
    }

    /// Trimmed, lowercased model names that `identity` supersedes, spelled every way they can
    /// appear in chunk metadata (canonical name plus aliases). Remember dedup accepts chunks
    /// recorded under these names, because chunk metadata is never rewritten by a re-embed.
    static func supersededModelNames(for identity: EmbeddingIdentity) -> Set<String> {
        guard let model = identity.model,
              let superseding = supersededModels[canonicalModel(model)] else {
            return []
        }
        var names = superseding.replaces
        for (alias, canonical) in modelAliases where superseding.replaces.contains(canonical) {
            names.insert(alias)
        }
        return names
    }

    /// `true` when a store with vectors but no binding must be treated as superseded for
    /// `identity` (legacy stores predate the binding, so their vector space is unknown).
    static func treatsUnboundVectorsAsSuperseded(for identity: EmbeddingIdentity) -> Bool {
        guard let model = identity.model else { return false }
        return supersededModels[canonicalModel(model)] != nil
    }

    /// - Parameter storeHasVectors: only consulted when the store has no binding.
    static func verdict(
        binding: MemoryBinding?,
        storeHasVectors: Bool,
        identity: EmbeddingIdentity
    ) -> Verdict {
        guard let binding, !binding.isEmpty else {
            if storeHasVectors,
               let model = identity.model,
               let superseding = supersededModels[canonicalModel(model)] {
                return .needsReembed(reason: superseding.reason)
            }
            return .compatible
        }
        guard let mismatch = mismatchReason(binding, with: identity) else {
            return .compatible
        }
        if let expected = binding.embeddingModel,
           let actual = identity.model,
           let superseding = supersededModels[canonicalModel(actual)],
           superseding.replaces.contains(canonicalModel(expected)) {
            var rebound = binding
            rebound.embeddingModel = actual
            if mismatchReason(rebound, with: identity) == nil {
                return .needsReembed(reason: superseding.reason)
            }
        }
        return .incompatible(reason: mismatch)
    }

    static func mismatchReason(_ binding: MemoryBinding, with identity: EmbeddingIdentity) -> String? {
        if let expected = binding.embeddingProvider,
           let actual = identity.provider,
           expected != actual {
            return "provider expected '\(expected)' got '\(actual)'"
        }
        if let expected = binding.embeddingModel {
            guard let actual = identity.model else {
                return "model expected '\(expected)' got nil"
            }
            if canonicalModel(expected) != canonicalModel(actual) {
                return "model expected '\(expected)' got '\(actual)'"
            }
        }
        if let expected = binding.embeddingDimensions {
            guard let raw = identity.dimensions else {
                return "dimensions expected \(expected) got nil"
            }
            guard let actual = UInt32(exactly: raw) else {
                return "dimensions could not be represented as UInt32"
            }
            if expected != actual {
                return "dimensions expected \(expected) got \(actual)"
            }
        }
        if let expected = binding.embeddingNormalized,
           let actual = identity.normalized,
           expected != actual {
            return "normalized expected \(expected) got \(actual)"
        }
        return nil
    }

    private static func canonicalModel(_ model: String) -> String {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return modelAliases[normalized] ?? normalized
    }
}
