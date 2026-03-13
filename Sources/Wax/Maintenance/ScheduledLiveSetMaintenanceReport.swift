import Foundation

package struct ScheduledLiveSetMaintenanceReport: Sendable, Equatable {
    package enum Outcome: String, Sendable, Equatable {
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

    package var outcome: Outcome
    package var triggeredByFlush: Bool
    package var flushCount: UInt64
    package var deadPayloadBytes: UInt64
    package var totalPayloadBytes: UInt64
    package var deadPayloadFraction: Double
    package var candidateURL: URL?
    package var rewriteReport: LiveSetRewriteReport?
    package var rollbackPerformed: Bool
    package var notes: [String]

    package init(
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
