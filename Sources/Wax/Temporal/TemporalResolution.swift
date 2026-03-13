import Foundation

package struct TemporalResolution: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case date
        case dateTime
        case range
    }

    package var kind: Kind
    package var start: Date
    package var end: Date?

    package init(kind: Kind, start: Date, end: Date? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Convert to half-package millisecond range expected by `SearchTimeRange`.
    package var asTimeRange: (afterMs: Int64, beforeMs: Int64) {
        let afterMs = Int64(start.timeIntervalSince1970 * 1000)
        let beforeDate: Date
        if let end {
            beforeDate = end
        } else {
            let calendar = Calendar(identifier: .gregorian)
            let startOfDay = calendar.startOfDay(for: start)
            beforeDate = calendar.date(byAdding: .day, value: 1, to: startOfDay)
                ?? start.addingTimeInterval(24 * 60 * 60)
        }
        let beforeMs = Int64(beforeDate.timeIntervalSince1970 * 1000)
        return (afterMs: afterMs, beforeMs: beforeMs)
    }
}
