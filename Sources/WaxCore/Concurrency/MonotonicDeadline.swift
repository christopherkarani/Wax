import Foundation

package extension ContinuousClock.Instant {
    /// Upper bound for a deadline built from seconds (about 31 years).
    private static let maximumDeadlineSeconds: Double = 1_000_000_000

    /// `now` plus `seconds` on the monotonic clock, so a wall-clock change cannot move it.
    ///
    /// Unlike `Duration.seconds(_:)`, this never traps: NaN and negative values give
    /// `now`, and infinite or huge values saturate at `maximumDeadlineSeconds`.
    static func deadline(afterSeconds seconds: Double) -> Self {
        let clamped: Double
        if seconds.isNaN || seconds <= 0 {
            clamped = 0
        } else {
            clamped = min(seconds, maximumDeadlineSeconds)
        }
        return ContinuousClock.now.advanced(by: .seconds(clamped))
    }

    /// Seconds until this instant; negative once it has passed.
    var secondsRemaining: Double {
        ContinuousClock.now.duration(to: self) / .seconds(1)
    }
}
