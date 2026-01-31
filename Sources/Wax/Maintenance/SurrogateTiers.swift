import Foundation

/// Hierarchical compression tiers for a surrogate.
///
/// Each tier represents a different level of compression:
/// - `full`: Maximum fidelity (~100 tokens)
/// - `gist`: Balanced compression (~25 tokens)
/// - `micro`: Entity + topic only (~8 tokens)
public struct SurrogateTiers: Sendable, Equatable, Codable, Hashable {
    /// Full surrogate - highest fidelity, most tokens
    public var full: String
    
    /// Gist surrogate - balanced compression
    public var gist: String
    
    /// Micro surrogate - minimal, entity + topic only
    public var micro: String
    
    /// Algorithm version for cache invalidation
    public var version: Int
    
    /// Generation timestamp (milliseconds since epoch)
    public var generatedAtMs: Int64
    
    public init(
        full: String,
        gist: String,
        micro: String,
        version: Int = 1,
        generatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.full = full
        self.gist = gist
        self.micro = micro
        self.version = version
        self.generatedAtMs = generatedAtMs
    }
}
