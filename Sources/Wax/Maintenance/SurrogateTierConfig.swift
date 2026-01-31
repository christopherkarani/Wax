import Foundation

/// Configuration for hierarchical surrogate tier token budgets.
public struct SurrogateTierConfig: Sendable, Equatable {
    /// Token budget for full tier
    public var fullMaxTokens: Int
    
    /// Token budget for gist tier
    public var gistMaxTokens: Int
    
    /// Token budget for micro tier
    public var microMaxTokens: Int
    
    public init(
        fullMaxTokens: Int = 100,
        gistMaxTokens: Int = 25,
        microMaxTokens: Int = 8
    ) {
        self.fullMaxTokens = fullMaxTokens
        self.gistMaxTokens = gistMaxTokens
        self.microMaxTokens = microMaxTokens
    }
    
    /// Default configuration
    public static let `default` = SurrogateTierConfig()
    
    /// Compact preset for memory-constrained devices
    public static let compact = SurrogateTierConfig(
        fullMaxTokens: 50,
        gistMaxTokens: 15,
        microMaxTokens: 5
    )
    
    /// Verbose preset for high-fidelity contexts
    public static let verbose = SurrogateTierConfig(
        fullMaxTokens: 150,
        gistMaxTokens: 40,
        microMaxTokens: 12
    )
}
