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

    /// Parses exactly `yyyy-MM-dd`, or that date followed by an ISO 8601 time: `T` (or a
    /// space), `HH:mm`, optional `:ss` and fraction, and an optional `Z` or `±HH:mm` offset.
    /// The day is the date as written, whatever offset follows it:
    /// "2023-08-22T23:30:00-07:00" and "2023-08-22T00:00:00Z" are both the 22nd. Returns `nil`
    /// for anything else, an impossible date, or trailing text.
    package init?(iso8601 raw: String) {
        var scanner = DigitScanner(bytes: Array(raw.utf8))
        guard let year = scanner.number(digits: 4, max: 9999), scanner.take("-"),
              let month = scanner.number(digits: 2, max: 12), scanner.take("-"),
              let day = scanner.number(digits: 2, max: 31),
              month >= 1, day >= 1, day <= Self.daysIn(year: year, month: month),
              scanner.isAtEnd || scanner.takeTime() else {
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

/// Reads fixed-width ASCII digits and separators from the front of a byte string.
private struct DigitScanner {
    let bytes: [UInt8]
    var index = 0

    var isAtEnd: Bool { index == bytes.count }

    mutating func take(_ character: Character) -> Bool {
        guard index < bytes.count, let ascii = character.asciiValue, bytes[index] == ascii else { return false }
        index += 1
        return true
    }

    mutating func number(digits: Int, max: Int) -> Int? {
        guard index + digits <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[index..<index + digits] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        guard value <= max else { return nil }
        index += digits
        return value
    }

    /// `T` or a space, `HH:mm`, optional `:ss[.fraction]`, optional `Z` or `±HH[:]mm`, then the end.
    mutating func takeTime() -> Bool {
        guard take("T") || take(" "), number(digits: 2, max: 23) != nil, take(":"),
              number(digits: 2, max: 59) != nil else { return false }
        if take(":") {
            guard number(digits: 2, max: 60) != nil else { return false }
            if take(".") {
                guard number(digits: 1, max: 9) != nil else { return false }
                while number(digits: 1, max: 9) != nil {}
            }
        }
        if isAtEnd { return true }
        if take("Z") { return isAtEnd }
        guard take("+") || take("-"), number(digits: 2, max: 14) != nil else { return false }
        _ = take(":")
        return number(digits: 2, max: 59) != nil && isAtEnd
    }
}
