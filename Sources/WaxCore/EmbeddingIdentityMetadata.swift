import Foundation

/// Canonical embedding-identity metadata keys written onto frames.
///
/// Writers always persist ``wax.embedding.*``. Readers dual-read legacy
/// ``memvid.embedding.*`` so stores written by older ``WaxVectorSearchSession``
/// paths remain compatible with remember-dedup without rewriting existing data.
package enum EmbeddingIdentityMetadata {
    package static let providerKey = "wax.embedding.provider"
    package static let modelKey = "wax.embedding.model"
    package static let dimensionKey = "wax.embedding.dimension"
    package static let normalizedKey = "wax.embedding.normalized"

    package static let legacyProviderKey = "memvid.embedding.provider"
    package static let legacyModelKey = "memvid.embedding.model"
    package static let legacyDimensionKey = "memvid.embedding.dimension"
    package static let legacyNormalizedKey = "memvid.embedding.normalized"

    package static func write(
        into entries: inout [String: String],
        provider: String?,
        model: String?,
        dimensions: Int?,
        normalized: Bool?
    ) {
        // Canonical writes must not leave conflicting legacy keys behind when
        // callers merge identity onto metadata that already carried memvid.*.
        entries.removeValue(forKey: legacyProviderKey)
        entries.removeValue(forKey: legacyModelKey)
        entries.removeValue(forKey: legacyDimensionKey)
        entries.removeValue(forKey: legacyNormalizedKey)

        if let provider {
            entries[providerKey] = provider
        }
        if let model {
            entries[modelKey] = model
        }
        if let dimensions {
            entries[dimensionKey] = String(dimensions)
        }
        if let normalized {
            entries[normalizedKey] = String(normalized)
        }
    }

    package static func provider(from entries: [String: String]) -> String? {
        entries[providerKey] ?? entries[legacyProviderKey]
    }

    package static func model(from entries: [String: String]) -> String? {
        entries[modelKey] ?? entries[legacyModelKey]
    }

    package static func dimension(from entries: [String: String]) -> String? {
        entries[dimensionKey] ?? entries[legacyDimensionKey]
    }

    package static func normalized(from entries: [String: String]) -> String? {
        entries[normalizedKey] ?? entries[legacyNormalizedKey]
    }
}
