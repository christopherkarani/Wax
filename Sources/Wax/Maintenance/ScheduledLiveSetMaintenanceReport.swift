import Foundation

public struct ScheduledLiveSetMaintenanceReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case disabled
        case cadenceSkipped
        case cooldownSkipped
        case idleSkipped
        case belowThreshold
        case alreadyRunningSkipped
        case rewriteSucceeded
        case rewriteFailed
        case validationFailedRolledBack
    }

    public var outcome: Outcome
    public var triggeredByFlush: Bool
    public var flushCount: UInt64
    public var deadPayloadBytes: UInt64
    public var totalPayloadBytes: UInt64
    public var deadPayloadFraction: Double
    public var candidateURL: URL?
    public var rewriteReport: LiveSetRewriteReport?
    public var rollbackPerformed: Bool
    public var notes: [String]

    public init(
        outcome: Outcome,
        triggeredByFlush: Bool,
        flushCount: UInt64,
        deadPayloadBytes: UInt64,
        totalPayloadBytes: UInt64,
        deadPayloadFraction: Double,
        candidateURL: URL?,
        rewriteReport: LiveSetRewriteReport?,
        rollbackPerformed: Bool,
        notes: [String]
    ) {
        self.outcome = outcome
        self.triggeredByFlush = triggeredByFlush
        self.flushCount = flushCount
        self.deadPayloadBytes = deadPayloadBytes
        self.totalPayloadBytes = totalPayloadBytes
        self.deadPayloadFraction = deadPayloadFraction
        self.candidateURL = candidateURL
        self.rewriteReport = rewriteReport
        self.rollbackPerformed = rollbackPerformed
        self.notes = notes
    }
}
