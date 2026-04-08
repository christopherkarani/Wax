import Foundation
import WaxCore
import WaxVectorSearch

enum MemoryBindingCompatibility {
    private static let modelAliases: [String: String] = [
        "minilmall": "minilm",
        "arctic": "arcticembeds",
    ]

    static func binding(from identity: EmbeddingIdentity) -> MemoryBinding {
        MemoryBinding(
            embeddingProvider: identity.provider,
            embeddingModel: identity.model,
            embeddingDimensions: identity.dimensions.map(UInt32.init),
            embeddingNormalized: identity.normalized
        )
    }

    static func isCompatible(_ binding: MemoryBinding, with identity: EmbeddingIdentity) -> Bool {
        mismatchReason(binding, with: identity) == nil
    }

    static func mismatchReason(_ binding: MemoryBinding, with identity: EmbeddingIdentity) -> String? {
        if let expected = binding.embeddingProvider,
           let actual = identity.provider,
           expected != actual {
            return "provider expected '\(expected)' got '\(actual)'"
        }
        if let expected = binding.embeddingModel,
           let actual = identity.model,
           canonicalModel(expected) != canonicalModel(actual) {
            return "model expected '\(expected)' got '\(actual)'"
        }
        if let expected = binding.embeddingDimensions {
            guard let actual = identity.dimensions.flatMap({ UInt32(exactly: $0) }) else {
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
