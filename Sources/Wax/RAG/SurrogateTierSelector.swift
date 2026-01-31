import Foundation

/// Context for selecting the appropriate surrogate tier.
public struct TierSelectionContext: Sendable {
    /// Frame creation timestamp (milliseconds)
    public var frameTimestamp: Int64
    
    /// Access statistics for the frame (if available)
    public var accessStats: FrameAccessStats?
    
    /// Query signals (if query-aware selection enabled)
    public var querySignals: QuerySignals?
    
    /// Current time (milliseconds)
    public var nowMs: Int64
    
    public init(
        frameTimestamp: Int64,
        accessStats: FrameAccessStats? = nil,
        querySignals: QuerySignals? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.frameTimestamp = frameTimestamp
        self.accessStats = accessStats
        self.querySignals = querySignals
        self.nowMs = nowMs
    }
}

/// Selects the appropriate surrogate tier based on policy and context.
public struct SurrogateTierSelector: Sendable {
    public var policy: TierSelectionPolicy
    public var scorer: ImportanceScorer
    
    /// How much query specificity boosts importance (0.0 - 1.0)
    public var queryBoostFactor: Float
    
    public init(
        policy: TierSelectionPolicy = .importanceBalanced,
        scorer: ImportanceScorer = ImportanceScorer(),
        queryBoostFactor: Float = 0.15
    ) {
        self.policy = policy
        self.scorer = scorer
        self.queryBoostFactor = queryBoostFactor
    }
    
    /// Select the appropriate tier for a frame based on policy and context.
    public func selectTier(context: TierSelectionContext) -> SurrogateTier {
        switch policy {
        case .disabled:
            return .full
            
        case .ageOnly(let thresholds):
            return selectByAge(context: context, thresholds: thresholds)
            
        case .importance(let thresholds):
            return selectByImportance(context: context, thresholds: thresholds)
        }
    }
    
    private func selectByAge(context: TierSelectionContext, thresholds: AgeThresholds) -> SurrogateTier {
        let ageMs = context.nowMs - context.frameTimestamp
        
        if ageMs < thresholds.recentMs {
            return .full
        } else if ageMs < thresholds.oldMs {
            return .gist
        } else {
            return .micro
        }
    }
    
    private func selectByImportance(context: TierSelectionContext, thresholds: ImportanceThresholds) -> SurrogateTier {
        // Calculate base importance
        var importance = scorer.score(
            frameTimestamp: context.frameTimestamp,
            accessStats: context.accessStats,
            nowMs: context.nowMs
        )
        
        // Apply query boost if query is specific
        if let querySignals = context.querySignals {
            importance.score += querySignals.specificityScore * queryBoostFactor
            importance.score = min(1.0, importance.score)
        }
        
        // Select tier based on boosted importance
        if importance.score >= thresholds.fullThreshold {
            return .full
        } else if importance.score >= thresholds.gistThreshold {
            return .gist
        } else {
            return .micro
        }
    }
    
    /// Extract the appropriate tier text from surrogate data.
    ///
    /// Handles both hierarchical (JSON) and legacy (plain text) formats.
    public static func extractTier(from data: Data, tier: SurrogateTier) -> String? {
        // Try hierarchical JSON format first
        if let tiers = try? JSONDecoder().decode(SurrogateTiers.self, from: data) {
            switch tier {
            case .full: return tiers.full
            case .gist: return tiers.gist
            case .micro: return tiers.micro
            }
        }
        
        // Fallback: legacy single-tier (plain text)
        return String(data: data, encoding: .utf8)
    }
}
