import Foundation

public struct TemporalNormalizer: Sendable {
    public let anchor: Date
    public let calendar: Calendar

    public init(anchor: Date = Date(), calendar: Calendar = .init(identifier: .gregorian)) {
        self.anchor = anchor
        self.calendar = calendar
    }

    public func resolve(_ phrase: String) throws -> TemporalResolution {
        let normalized = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            throw WaxError.io("unsupported temporal phrase: \(phrase)")
        }

        if let fixed = resolveFixed(normalized) { return fixed }
        if let relativeDays = resolveRelativeDays(normalized) { return relativeDays }
        if let relativeWeeks = resolveRelativeWeeks(normalized) { return relativeWeeks }
        if let weekday = resolveWeekdayPhrase(normalized) { return weekday }
        if let quarter = resolveQuarter(normalized) { return quarter }

        throw WaxError.io("unsupported temporal phrase: \(phrase)")
    }

    private func resolveFixed(_ phrase: String) -> TemporalResolution? {
        switch phrase {
        case "today":
            return dateResolution(anchor)
        case "yesterday":
            return dateResolution(addDays(-1))
        case "tomorrow":
            return dateResolution(addDays(1))
        case "last week":
            return weekRange(offsetWeeks: -1)
        case "this week":
            return weekRange(offsetWeeks: 0)
        case "next week":
            return weekRange(offsetWeeks: 1)
        case "last month":
            return monthRange(offsetMonths: -1)
        case "this month":
            return monthRange(offsetMonths: 0)
        case "next month":
            return monthRange(offsetMonths: 1)
        default:
            return nil
        }
    }

    private func resolveRelativeDays(_ phrase: String) -> TemporalResolution? {
        let parts = phrase.split(separator: " ")
        if parts.count == 3, parts[0] == "in", let amount = Int(parts[1]), parts[2] == "days" || parts[2] == "day" {
            return dateResolution(addDays(amount))
        }
        if parts.count == 3, let amount = Int(parts[0]), parts[2] == "ago", parts[1] == "days" || parts[1] == "day" {
            return dateResolution(addDays(-amount))
        }
        return nil
    }

    private func resolveRelativeWeeks(_ phrase: String) -> TemporalResolution? {
        let parts = phrase.split(separator: " ")
        if parts.count == 3, parts[0] == "in", let amount = Int(parts[1]), parts[2] == "weeks" || parts[2] == "week" {
            return dateResolution(addWeeks(amount))
        }
        if parts.count == 3, let amount = Int(parts[0]), parts[2] == "ago", parts[1] == "weeks" || parts[1] == "week" {
            return dateResolution(addWeeks(-amount))
        }
        return nil
    }

    private func resolveWeekdayPhrase(_ phrase: String) -> TemporalResolution? {
        let parts = phrase.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let direction = String(parts[0])
        guard let targetWeekday = weekdayNumber(for: String(parts[1])) else { return nil }
        let anchorWeekday = calendar.component(.weekday, from: anchor)

        let dayDelta: Int
        switch direction {
        case "last":
            dayDelta = previousWeekdayDelta(anchorWeekday: anchorWeekday, targetWeekday: targetWeekday)
        case "next":
            dayDelta = nextWeekdayDelta(anchorWeekday: anchorWeekday, targetWeekday: targetWeekday)
        case "this":
            dayDelta = targetWeekday - anchorWeekday
        default:
            return nil
        }
        return dateResolution(addDays(dayDelta))
    }

    private func resolveQuarter(_ phrase: String) -> TemporalResolution? {
        let parts = phrase.split(separator: " ")
        guard parts.count == 2 else { return nil }

        let qToken = String(parts[0])
        guard qToken.count == 2,
              qToken.first == "q",
              let quarter = Int(String(qToken.suffix(1))),
              (1...4).contains(quarter),
              let year = Int(parts[1]),
              (1970...2100).contains(year) else {
            return nil
        }

        let startMonth = ((quarter - 1) * 3) + 1
        let startComponents = DateComponents(year: year, month: startMonth, day: 1)
        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(byAdding: .month, value: 3, to: start) else {
            return nil
        }
        return TemporalResolution(kind: .range, start: start, end: end)
    }

    private func dateResolution(_ date: Date) -> TemporalResolution {
        TemporalResolution(kind: .date, start: calendar.startOfDay(for: date))
    }

    private func weekRange(offsetWeeks: Int) -> TemporalResolution? {
        guard let shifted = calendar.date(byAdding: .weekOfYear, value: offsetWeeks, to: anchor),
              let interval = calendar.dateInterval(of: .weekOfYear, for: shifted) else {
            return nil
        }
        return TemporalResolution(kind: .range, start: interval.start, end: interval.end)
    }

    private func monthRange(offsetMonths: Int) -> TemporalResolution? {
        guard let shifted = calendar.date(byAdding: .month, value: offsetMonths, to: anchor) else {
            return nil
        }
        let comps = calendar.dateComponents([.year, .month], from: shifted)
        guard let year = comps.year, let month = comps.month else { return nil }
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else {
            return nil
        }
        return TemporalResolution(kind: .range, start: start, end: end)
    }

    private func addDays(_ value: Int) -> Date {
        calendar.date(byAdding: .day, value: value, to: anchor) ?? anchor
    }

    private func addWeeks(_ value: Int) -> Date {
        calendar.date(byAdding: .weekOfYear, value: value, to: anchor) ?? anchor
    }

    private func previousWeekdayDelta(anchorWeekday: Int, targetWeekday: Int) -> Int {
        let delta = targetWeekday - anchorWeekday
        return delta >= 0 ? delta - 7 : delta
    }

    private func nextWeekdayDelta(anchorWeekday: Int, targetWeekday: Int) -> Int {
        let delta = targetWeekday - anchorWeekday
        return delta <= 0 ? delta + 7 : delta
    }

    private func weekdayNumber(for token: String) -> Int? {
        switch token {
        case "sunday", "sun":
            return 1
        case "monday", "mon":
            return 2
        case "tuesday", "tue", "tues":
            return 3
        case "wednesday", "wed":
            return 4
        case "thursday", "thu", "thurs":
            return 5
        case "friday", "fri":
            return 6
        case "saturday", "sat":
            return 7
        default:
            return nil
        }
    }
}
