import Foundation

public protocol SurrogateGenerator: Sendable {
    /// Stable identifier for persisted metadata (e.g. "extractive_v1", "smollm_360m_q4_v1")
    var algorithmID: String { get }

    /// Generate a surrogate for a source frame/chunk.
    /// Must be safe for offline caching and bounded by `maxTokens`.
    func generateSurrogate(sourceText: String, maxTokens: Int) async throws -> String
}

/// Extended protocol for hierarchical surrogate generation.
/// Generates all compression tiers in a single optimized pass.
public protocol HierarchicalSurrogateGenerator: SurrogateGenerator {
    /// Generate all compression tiers for a source text.
    func generateTiers(
        sourceText: String,
        config: SurrogateTierConfig
    ) async throws -> SurrogateTiers
}

// Default implementation for HierarchicalSurrogateGenerator
extension HierarchicalSurrogateGenerator {
    public func generateTiers(
        sourceText: String,
        config: SurrogateTierConfig
    ) async throws -> SurrogateTiers {
        // Generate each tier separately (suboptimal but works for any generator)
        let full = try await generateSurrogate(
            sourceText: sourceText,
            maxTokens: config.fullMaxTokens
        )
        let gist = try await generateSurrogate(
            sourceText: sourceText,
            maxTokens: config.gistMaxTokens
        )
        let micro = try await generateSurrogate(
            sourceText: sourceText,
            maxTokens: config.microMaxTokens
        )
        
        return SurrogateTiers(full: full, gist: gist, micro: micro)
    }
}
