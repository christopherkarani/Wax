import Foundation

public struct TemporalResolution: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case date
        case dateTime
        case range
    }

    public var kind: Kind
    public var start: Date
    public var end: Date?

    public init(kind: Kind, start: Date, end: Date? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Convert to half-open millisecond range expected by `TimeRange`.
    public var asTimeRange: (afterMs: Int64, beforeMs: Int64) {
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
