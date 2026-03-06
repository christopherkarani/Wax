import Foundation

package struct LiveSetRewriteSchedule: Sendable, Equatable {
    package var enabled: Bool
    package var checkEveryFlushes: Int
    package var minDeadPayloadBytes: UInt64
    package var minDeadPayloadFraction: Double
    package var minimumCompactionGainBytes: UInt64
    package var minimumIdleMs: Int
    package var minIntervalMs: Int
    package var verifyDeep: Bool
    package var destinationDirectory: URL?
    package var keepLatestCandidates: Int
    package var promoteValidatedCandidateOnClose: Bool

    package init(
        enabled: Bool = false,
        checkEveryFlushes: Int = 32,
        minDeadPayloadBytes: UInt64 = 64 * 1024 * 1024,
        minDeadPayloadFraction: Double = 0.25,
        minimumCompactionGainBytes: UInt64 = 0,
        minimumIdleMs: Int = 15_000,
        minIntervalMs: Int = 5 * 60_000,
        verifyDeep: Bool = false,
        destinationDirectory: URL? = nil,
        keepLatestCandidates: Int = 2,
        promoteValidatedCandidateOnClose: Bool = false
    ) {
        self.enabled = enabled
        self.checkEveryFlushes = checkEveryFlushes
        self.minDeadPayloadBytes = minDeadPayloadBytes
        self.minDeadPayloadFraction = minDeadPayloadFraction
        self.minimumCompactionGainBytes = minimumCompactionGainBytes
        self.minimumIdleMs = minimumIdleMs
        self.minIntervalMs = minIntervalMs
        self.verifyDeep = verifyDeep
        self.destinationDirectory = destinationDirectory
        self.keepLatestCandidates = keepLatestCandidates
        self.promoteValidatedCandidateOnClose = promoteValidatedCandidateOnClose
    }

    package static let disabled = LiveSetRewriteSchedule()

    package static let conservativeAutomatic = LiveSetRewriteSchedule(
        enabled: true,
        checkEveryFlushes: 32,
        minDeadPayloadBytes: 64 * 1024 * 1024,
        minDeadPayloadFraction: 0.25,
        minimumCompactionGainBytes: 0,
        minimumIdleMs: 15_000,
        minIntervalMs: 5 * 60_000,
        verifyDeep: false,
        destinationDirectory: nil,
        keepLatestCandidates: 2,
        promoteValidatedCandidateOnClose: true
    )
}
