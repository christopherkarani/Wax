import Foundation

/// Importance score for a frame, used for tier selection.
public struct ImportanceScore: Sendable {
    /// Combined score (0.0 - 1.0)
    public var score: Float
    
    /// Age component contribution
    public var ageComponent: Float
    
    /// Access frequency component contribution
    public var frequencyComponent: Float
    
    /// Recency of access component contribution
    public var recencyComponent: Float
}

/// Configuration for importance scoring weights and decay rates.
public struct ImportanceScoringConfig: Sendable, Equatable {
    /// Weight for memory age component (0.0 - 1.0)
    public var ageWeight: Float
    
    /// Weight for access frequency component (0.0 - 1.0)
    public var frequencyWeight: Float
    
    /// Weight for recency of last access component (0.0 - 1.0)
    public var recencyWeight: Float
    
    /// Half-life for age decay in hours (age at which importance drops to ~37%)
    public var ageHalfLifeHours: Float
    
    /// Half-life for recency decay in hours
    public var recencyHalfLifeHours: Float
    
    public init(
        ageWeight: Float = 0.3,
        frequencyWeight: Float = 0.4,
        recencyWeight: Float = 0.3,
        ageHalfLifeHours: Float = 168,  // 1 week
        recencyHalfLifeHours: Float = 24  // 1 day
    ) {
        self.ageWeight = ageWeight
        self.frequencyWeight = frequencyWeight
        self.recencyWeight = recencyWeight
        self.ageHalfLifeHours = ageHalfLifeHours
        self.recencyHalfLifeHours = recencyHalfLifeHours
    }
    
    public static let `default` = ImportanceScoringConfig()
}

/// Calculates importance scores for frames based on age and access patterns.
public struct ImportanceScorer: Sendable {
    public var config: ImportanceScoringConfig
    
    public init(config: ImportanceScoringConfig = .default) {
        self.config = config
    }
    
    /// Calculate importance score for a frame.
    ///
    /// - Parameters:
    ///   - frameTimestamp: Frame creation timestamp (milliseconds)
    ///   - accessStats: Optional access statistics for the frame
    ///   - nowMs: Current time (milliseconds)
    /// - Returns: Importance score with component breakdown
    public func score(
        frameTimestamp: Int64,
        accessStats: FrameAccessStats?,
        nowMs: Int64
    ) -> ImportanceScore {
        // Age component: newer = higher importance (exponential decay)
        let ageMs = Float(max(0, nowMs - frameTimestamp))
        let ageHours = ageMs / (1000 * 60 * 60)
        let ageComponent = exp(-ageHours / config.ageHalfLifeHours)
        
        // Frequency component: more accesses = higher importance (log scale, capped)
        let frequencyComponent: Float
        if let stats = accessStats {
            // log(1 + count) / log(150) normalizes to ~1.0 at 150 accesses
            frequencyComponent = min(1.0, log(Float(stats.accessCount) + 1) / 5.0)
        } else {
            frequencyComponent = 0.0
        }
        
        // Recency component: recently accessed = higher importance
        let recencyComponent: Float
        if let stats = accessStats {
            let hoursSinceAccess = Float(max(0, nowMs - stats.lastAccessMs)) / (1000 * 60 * 60)
            recencyComponent = exp(-hoursSinceAccess / config.recencyHalfLifeHours)
        } else {
            recencyComponent = 0.0
        }
        
        // Weighted sum, normalized to 0-1
        let totalWeight = config.ageWeight + config.frequencyWeight + config.recencyWeight
        let rawScore: Float
        if totalWeight > 0 {
            rawScore = (
                config.ageWeight * ageComponent +
                config.frequencyWeight * frequencyComponent +
                config.recencyWeight * recencyComponent
            ) / totalWeight
        } else {
            rawScore = ageComponent  // Fallback to age-only if weights are zero
        }
        
        return ImportanceScore(
            score: rawScore,
            ageComponent: ageComponent,
            frequencyComponent: frequencyComponent,
            recencyComponent: recencyComponent
        )
    }
}
