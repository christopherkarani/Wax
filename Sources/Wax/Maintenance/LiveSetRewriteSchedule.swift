import Foundation

public struct LiveSetRewriteSchedule: Sendable, Equatable {
    public var enabled: Bool
    public var checkEveryFlushes: Int
    public var minDeadPayloadBytes: UInt64
    public var minDeadPayloadFraction: Double
    public var minimumCompactionGainBytes: UInt64
    public var minimumIdleMs: Int
    public var minIntervalMs: Int
    public var verifyDeep: Bool
    public var destinationDirectory: URL?
    public var keepLatestCandidates: Int

    public init(
        enabled: Bool = false,
        checkEveryFlushes: Int = 32,
        minDeadPayloadBytes: UInt64 = 64 * 1024 * 1024,
        minDeadPayloadFraction: Double = 0.25,
        minimumCompactionGainBytes: UInt64 = 0,
        minimumIdleMs: Int = 15_000,
        minIntervalMs: Int = 5 * 60_000,
        verifyDeep: Bool = false,
        destinationDirectory: URL? = nil,
        keepLatestCandidates: Int = 2
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
    }

    public static let disabled = LiveSetRewriteSchedule()
}
