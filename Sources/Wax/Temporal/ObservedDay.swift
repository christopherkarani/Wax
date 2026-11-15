import Foundation

/// The calendar day a text was observed on: the day its relative date phrases resolve against.
package struct ObservedDay: Sendable, Hashable {
    package let year: Int
    package let month: Int
    package let day: Int

    package init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`, optionally followed by an ISO 8601 time (`T…` or a space). The
    /// day is the one written, whatever offset follows it: "2023-08-22T23:30:00-07:00" is the
    /// 22nd, as the writer saw it. Returns `nil` for anything else or an impossible date.
    package init?(iso8601 raw: String) {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else {
            return nil
        }
        if bytes.count > 10, bytes[10] != UInt8(ascii: "T"), bytes[10] != UInt8(ascii: " ") {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              (1...12).contains(month), day >= 1, day <= Self.daysIn(year: year, month: month) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    /// Today in `timeZone`.
    package static func today(timeZone: TimeZone = .current, now: Date = Date()) -> ObservedDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return ObservedDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    package var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: - Arithmetic

    /// Days since 1970-01-01 (proleptic Gregorian), so day arithmetic needs no calendar or time zone.
    var dayNumber: Int {
        // Howard Hinnant's days_from_civil.
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    init(dayNumber: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        self.init(year: year, month: month, day: day)
    }

    func adding(days: Int) -> ObservedDay {
        ObservedDay(dayNumber: dayNumber + days)
    }

    /// ISO weekday: Monday 1 … Sunday 7.
    var isoWeekday: Int {
        // 1970-01-01 was a Thursday (4).
        ((dayNumber % 7) + 7 + 3) % 7 + 1
    }

    /// Monday of this day's ISO week.
    var weekStart: ObservedDay {
        adding(days: 1 - isoWeekday)
    }

    /// The month `months` after this day's month, as (year, month).
    func month(adding months: Int) -> (year: Int, month: Int) {
        let index = year * 12 + (month - 1) + months
        let year = index >= 0 ? index / 12 : (index - 11) / 12
        return (year, index - year * 12 + 1)
    }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
