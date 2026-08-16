import Foundation

/// Shared human-readable formatting for lock-timeout labels.
package enum DurationFormatting {
    package static func format(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
        if seconds == 0 {
            return "0s"
        }
        return String(format: "%.2fs", seconds)
    }
}
