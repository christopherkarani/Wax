import Foundation

package struct MaintenanceOptions: Sendable, Equatable {
    package var maxFrames: Int?
    package var maxWallTimeMs: Int?
    package var surrogateMaxTokens: Int
    package var overwriteExisting: Bool
    
    /// Enable hierarchical surrogate generation (full/gist/micro tiers)
    package var enableHierarchicalSurrogates: Bool
    
    /// Token budgets for each tier (used when enableHierarchicalSurrogates is true)
    package var tierConfig: SurrogateTierConfig

    package init(
        maxFrames: Int? = nil,
        maxWallTimeMs: Int? = nil,
        surrogateMaxTokens: Int = 60,
        overwriteExisting: Bool = false,
        enableHierarchicalSurrogates: Bool = true,
        tierConfig: SurrogateTierConfig = .default
    ) {
        self.maxFrames = maxFrames
        self.maxWallTimeMs = maxWallTimeMs
        self.surrogateMaxTokens = surrogateMaxTokens
        self.overwriteExisting = overwriteExisting
        self.enableHierarchicalSurrogates = enableHierarchicalSurrogates
        self.tierConfig = tierConfig
    }
}


