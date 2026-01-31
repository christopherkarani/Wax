import Foundation

public struct MaintenanceOptions: Sendable, Equatable {
    public var maxFrames: Int?
    public var maxWallTimeMs: Int?
    public var surrogateMaxTokens: Int
    public var overwriteExisting: Bool
    
    /// Enable hierarchical surrogate generation (full/gist/micro tiers)
    public var enableHierarchicalSurrogates: Bool
    
    /// Token budgets for each tier (used when enableHierarchicalSurrogates is true)
    public var tierConfig: SurrogateTierConfig

    public init(
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


