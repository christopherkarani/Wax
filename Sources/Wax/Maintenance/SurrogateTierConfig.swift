import Foundation

/// Configuration for hierarchical surrogate tier token budgets.
package struct SurrogateTierConfig: Sendable, Equatable {
    /// Token budget for full tier
    package var fullMaxTokens: Int
    
    /// Token budget for gist tier
    package var gistMaxTokens: Int
    
    /// Token budget for micro tier
    package var microMaxTokens: Int
    
    package init(
        fullMaxTokens: Int = 100,
        gistMaxTokens: Int = 25,
        microMaxTokens: Int = 8
    ) {
        self.fullMaxTokens = fullMaxTokens
        self.gistMaxTokens = gistMaxTokens
        self.microMaxTokens = microMaxTokens
    }
    
    /// Default configuration
    package static let `default` = SurrogateTierConfig()
    
    /// Compact preset for memory-constrained devices
    package static let compact = SurrogateTierConfig(
        fullMaxTokens: 50,
        gistMaxTokens: 15,
        microMaxTokens: 5
    )
    
    /// Verbose preset for high-fidelity contexts
    package static let verbose = SurrogateTierConfig(
        fullMaxTokens: 150,
        gistMaxTokens: 40,
        microMaxTokens: 12
    )
}
