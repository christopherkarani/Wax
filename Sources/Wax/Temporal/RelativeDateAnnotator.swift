import Foundation

/// Adds the absolute date after English relative date phrases, against the day the text was
/// observed: "yesterday" becomes "yesterday (21 Aug 2023)". The original wording stays, and
/// each insertion is reported so the original text can be rebuilt byte for byte.
///
/// Conservative by design: a phrase is left alone when its meaning depends on context the
/// text does not settle. That covers possessives ("last week's report"), quoted speech,
/// phrases with an absolute date already next to them, "the last week" (the past seven
/// days), "last" meaning final ("my last week at Acme") and possessive periods ("my next
/// week off"), "next Friday" and "this Friday" (readers split on which Friday), "in two
/// days" (a date or a duration), vague or partial amounts ("a few days ago", "over a year
/// ago", "twenty-two years ago", "2–3 weeks ago"), phrases that move the anchor ("a week
/// from today", "the week before last week"), backshifted reported speech ("he said he
/// would come tomorrow"), and capitalized names ("the Today show").
///
/// Each phrase reads a bounded window of text around it, so annotating is linear in the
/// length of the text.
package struct RelativeDateAnnotator: Sendable {
    /// Bytes added to the annotated text, at a UTF-8 offset into that text.
    package struct Insertion: Sendable, Equatable {
        package var utf8Offset: Int
        package var utf8Length: Int
    }

    package struct Result: Sendable, Equatable {
        package var text: String
        package var insertions: [Insertion]
    }

    package let observedDay: ObservedDay

    package init(observedDay: ObservedDay) {
        self.observedDay = observedDay
    }

    package func annotate(_ text: String) -> Result {
        var work = 0
        return annotate(text, work: &work)
    }

    /// Annotates `text` and adds to `work` the UTF-16 units read: one text length for each
    /// whole-text pass, plus every unit a per-phrase guard reads. Tests use it to check that
    /// the cost stays linear in the text without timing anything.
    package func annotate(_ text: String, work: inout Int) -> Result {
        let unchanged = Result(text: text, insertions: [])
        guard let regex = Self.phraseRegex else { return unchanged }
        let source = text as NSString
        work += source.length
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return unchanged }

        // The quote scan and the reporting-verb pass.
        work += 2 * source.length
        let scan = TextScan(quoted: Self.quotedLocations(in: source), reports: Self.reportLocations(in: text, source))
        var output = ""
        var outputUTF8 = 0
        var cursor = 0
        var insertions: [Insertion] = []
        for match in matches {
            guard let label = label(for: match, in: source, scan: scan, work: &work) else { continue }
            let end = match.range.location + match.range.length
            work += end - cursor
            let kept = source.substring(with: NSRange(location: cursor, length: end - cursor))
            output += kept
            outputUTF8 += kept.utf8.count
            let insertion = " (\(label))"
            insertions.append(Insertion(utf8Offset: outputUTF8, utf8Length: insertion.utf8.count))
            output += insertion
            outputUTF8 += insertion.utf8.count
            cursor = end
        }
        guard !insertions.isEmpty else { return unchanged }
        work += source.length - cursor
        output += source.substring(from: cursor)
        return Result(text: output, insertions: insertions)
    }

    // MARK: - Resolution

    /// Whole-text facts the per-phrase guards look up, computed once per text.
    private struct TextScan {
        /// UTF-16 locations inside quotes.
        let quoted: IndexSet
        /// Sorted start locations of reporting verbs, each with any "had" or "'d" before it.
        let reports: [Int]
    }

    private func label(
        for match: NSTextCheckingResult,
        in source: NSString,
        scan: TextScan,
        work: inout Int
    ) -> String? {
        guard !scan.quoted.contains(match.range.location) else { return nil }
        let context = Self.context(of: match.range, in: source)
        work += context.before.utf16.count + context.after.utf16.count
        let previous = Self.previousWords(in: context.before, work: &work)
        guard Self.isAnnotatable(match.range, in: source, context: context, previous: previous, work: &work) else {
            return nil
        }
        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound else { return nil }
            return source.substring(with: range).lowercased()
        }
        let phrase = source.substring(with: match.range).lowercased()
        guard !Self.isFinalOrPossessive(phrase, previous: previous, after: context.after, work: &work) else { return nil }
        // "a week from today", "the week before last week", "since yesterday": not the date.
        if let word = previous.first, Self.anchorMovingWords.contains(word) { return nil }
        // "He said last month that he would come next week": next week from when he said it.
        guard !Self.isBackshiftedReport(in: source, before: match.range.location, reports: scan.reports, work: &work) else {
            return nil
        }
        guard let label = resolve(group, previous: previous) else { return nil }
        // Already followed by its own label: annotated before, in any year.
        work += label.utf16.count
        guard !context.after.hasPrefix(" (\(label))") else { return nil }
        return label
    }

    private func resolve(_ group: (String) -> String?, previous: [String]) -> String? {
        let day = observedDay
        if group("before") != nil { return Self.format(day.adding(days: -2)) }
        if group("after") != nil { return Self.format(day.adding(days: 2)) }
        if group("lastnight") != nil { return Self.format(day.adding(days: -1)) }
        if group("yesterday") != nil { return Self.format(day.adding(days: -1)) }
        if group("today") != nil { return Self.format(day) }
        if group("tomorrow") != nil { return Self.format(day.adding(days: 1)) }
        if let amount = group("agoN").flatMap(Self.amount), let unit = group("agoUnit") {
            guard !Self.isPartOfLargerAmount(previous), !Self.isQualifiedAmount(previous) else { return nil }
            return agoLabel(amount: amount, unit: unit)
        }
        if let weekday = group("coming").flatMap(Self.isoWeekday) {
            let ahead = (weekday - day.isoWeekday + 7) % 7
            return Self.format(day.adding(days: ahead == 0 ? 7 : ahead))
        }
        if let weekday = group("lastwd").flatMap(Self.isoWeekday) {
            let back = (day.isoWeekday - weekday + 7) % 7
            return Self.format(day.adding(days: -(back == 0 ? 7 : back)))
        }
        if let direction = group("rel"), let unit = group("relUnit") {
            return periodLabel(direction: direction, unit: unit)
        }
        return nil
    }

    private func agoLabel(amount: Int, unit: String) -> String {
        let day = observedDay
        switch unit {
        case "day":
            return Self.format(day.adding(days: -amount))
        case "week":
            return Self.formatWeek(startingOn: day.adding(days: -7 * amount).weekStart)
        case "month":
            let month = day.month(adding: -amount)
            return Self.formatMonth(year: month.year, month: month.month)
        default:
            return String(day.year - amount)
        }
    }

    private func periodLabel(direction: String, unit: String) -> String? {
        let offset = direction == "last" ? -1 : (direction == "next" ? 1 : 0)
        let day = observedDay
        switch unit {
        case "week":
            return Self.formatWeek(startingOn: day.weekStart.adding(days: 7 * offset))
        case "weekend":
            switch direction {
            case "this":
                return Self.formatRange(day.weekStart.adding(days: 5), day.weekStart.adding(days: 6))
            case "last":
                // On a Saturday or Sunday, "last weekend" may be this one or the one before.
                guard day.isoWeekday <= 5 else { return nil }
                return Self.formatRange(day.weekStart.adding(days: -2), day.weekStart.adding(days: -1))
            default:
                // "next weekend": the coming one or the one after it.
                return nil
            }
        case "month":
            let month = day.month(adding: offset)
            return Self.formatMonth(year: month.year, month: month.month)
        default:
            return String(day.year + offset)
        }
    }

    // MARK: - Guards

    /// UTF-16 units of text the guards read before and after a phrase, so each phrase costs
    /// the same however long the text is.
    private static let beforeWindow = 60
    private static let afterWindow = 60

    /// Words that, before the phrase, change its meaning: "the last week" is the past seven
    /// days, "every last Friday" is not a date.
    private static let blockingPreviousWords: Set<String> = ["the", "every", "each", "per", "a", "an"]
    /// Before "last", these make it "final": "my last week at Acme", "the second last night".
    private static let finalDeterminers: Set<String> = [
        "my", "your", "his", "its", "our", "their", "whose",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "final",
    ]
    /// Before "last", possessive ("her last week") or an object ("I saw her last week").
    private static let objectDeterminers: Set<String> = ["her", "that", "this", "these", "those"]
    /// Past verbs whose object can be one of ``objectDeterminers``: "I saw her last Friday."
    private static let pastVerbs: Set<String> = [
        "saw", "met", "called", "texted", "emailed", "messaged", "visited", "told", "asked", "heard",
        "did", "fixed", "bought", "finished", "watched", "sent", "got",
    ]
    /// Words that start a new clause after a phrase: "I saw her last Friday but …".
    private static let clauseWords: Set<String> = ["and", "but", "so", "because", "when"]
    /// Before "next", these make it a possessive period: "my next week off".
    private static let nextPossessives: Set<String> = [
        "my", "your", "his", "its", "our", "their", "whose", "that", "this",
    ]
    /// Before a phrase, these move the date elsewhere: "a week from today", "after last Friday".
    private static let anchorMovingWords: Set<String> = ["before", "after", "from", "ago", "since"]
    /// Before "N days ago", these make N part of a larger amount: "twenty five", "2 or 3".
    private static let largerAmountWords: Set<String> = [
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "and", "or", "to", "through", "ish",
    ]
    /// Before "N days ago", these make the amount vague.
    private static let qualifierWords: Set<String> = [
        "over", "under", "almost", "nearly", "about", "around", "roughly", "within",
    ]
    private static let qualifierPairs: Set<String> = [
        "more than", "less than", "fewer than", "at least", "at most", "up to", "not even", "upwards of",
        "well over",
    ]
    /// UTF-16 units read back toward the sentence start for a reporting verb.
    private static let reportWindow = 200

    /// The text just before and just after `range`, at most a window each.
    private static func context(of range: NSRange, in source: NSString) -> (before: String, after: String) {
        let start = max(0, range.location - beforeWindow)
        let end = range.location + range.length
        let before = source.substring(with: NSRange(location: start, length: range.location - start))
        let after = source.substring(with: NSRange(location: end, length: min(afterWindow, source.length - end)))
        return (before, after)
    }

    private static func isAnnotatable(
        _ range: NSRange,
        in source: NSString,
        context: (before: String, after: String),
        previous: [String],
        work: inout Int
    ) -> Bool {
        let (before, following) = context
        // Possessive, hyphenated, or followed by "of" ("last week of August").
        if following.hasPrefix("'s") || following.hasPrefix("’s") || following.hasPrefix("-") { return false }
        work += 4
        if let ofRegex, ofRegex.firstMatch(in: following, range: NSRange(location: 0, length: min(4, (following as NSString).length))) != nil {
            return false
        }
        if let word = previous.first, blockingPreviousWords.contains(word) { return false }
        if isCapitalizedMidSentence(range, in: source, before: before, work: &work) { return false }
        return !hasAbsoluteDateNearby(before: before, after: following, work: &work)
    }

    /// Up to the two words before the phrase, nearest first, lowercased.
    private static func previousWords(in before: String, work: inout Int) -> [String] {
        var words: [String] = []
        var end = before.endIndex
        while words.count < 2 {
            while end > before.startIndex, " \t".contains(before[before.index(before: end)]) {
                end = before.index(before: end)
                work += 1
            }
            var start = end
            while start > before.startIndex, before[before.index(before: start)].isLetter {
                start = before.index(before: start)
                work += 1
            }
            guard start < end else { break }
            words.append(before[start..<end].lowercased())
            end = start
        }
        return words
    }

    private static func isPartOfLargerAmount(_ previous: [String]) -> Bool {
        previous.first.map(largerAmountWords.contains) ?? false
    }

    private static func isQualifiedAmount(_ previous: [String]) -> Bool {
        guard let nearest = previous.first else { return false }
        if qualifierWords.contains(nearest) { return true }
        return previous.count == 2 && qualifierPairs.contains("\(previous[1]) \(nearest)")
    }

    /// "my last week at Acme", "our next year", "her last week": a period someone has, not a
    /// date. "her", "that", "this", "these" and "those" before "last" count only when they are
    /// not the object of a past verb that ends the clause ("I saw her last Friday.").
    private static func isFinalOrPossessive(_ phrase: String, previous: [String], after: String, work: inout Int) -> Bool {
        guard let word = previous.first else { return false }
        if phrase.hasPrefix("next") { return nextPossessives.contains(word) }
        guard phrase.hasPrefix("last") else { return false }
        if finalDeterminers.contains(word) { return true }
        guard objectDeterminers.contains(word) else { return false }
        work += after.utf16.count
        return !(previous.count == 2 && pastVerbs.contains(previous[1]) && endsClause(after))
    }

    private static func endsClause(_ after: String) -> Bool {
        let rest = after.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = rest.first else { return true }
        if ".,!?;:\n".contains(first) { return true }
        return clauseWords.contains(rest.prefix(while: { $0.isLetter }).lowercased())
    }

    /// Start locations of reporting verbs, with any "had" or "'d" before them, in text order.
    private static func reportLocations(in text: String, _ source: NSString) -> [Int] {
        guard let reportingVerbRegex else { return [] }
        return reportingVerbRegex.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range.location)
    }

    /// The sentence before `location` has a reporting verb and then a backshift ("said …
    /// would", "told me she had"), or a pluperfect report ("he'd said"), so its times are
    /// relative to the report, not the observation.
    private static func isBackshiftedReport(
        in source: NSString,
        before location: Int,
        reports: [Int],
        work: inout Int
    ) -> Bool {
        guard let backshiftRegex, !reports.isEmpty else { return false }
        let start = sentenceStart(in: source, before: location, work: &work)
        // The first reporting verb at or after the sentence start.
        var low = 0
        var high = reports.count
        while low < high {
            work += 1
            let middle = (low + high) / 2
            if reports[middle] < start { low = middle + 1 } else { high = middle }
        }
        guard low < reports.count, reports[low] < location else { return false }
        work += location - reports[low]
        let slice = source.substring(with: NSRange(location: reports[low], length: location - reports[low]))
        return backshiftRegex.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) != nil
    }

    /// Where the sentence holding `location` starts, at most ``reportWindow`` units back. A
    /// period ends a sentence only before whitespace and an uppercase letter, and not after
    /// an abbreviation or a single letter ("Dr. Lee", "e.g. tomorrow", "J. Smith").
    private static func sentenceStart(in source: NSString, before location: Int, work: inout Int) -> Int {
        let floor = max(0, location - reportWindow)
        var index = location - 1
        while index >= floor {
            work += 1
            switch source.character(at: index) {
            case 0x0A, 0x21, 0x3F: // newline ! ?
                return index + 1
            case 0x2E where endsSentence(periodAt: index, in: source, work: &work):
                return index + 1
            default:
                index -= 1
            }
        }
        return floor
    }

    private static func endsSentence(periodAt index: Int, in source: NSString, work: inout Int) -> Bool {
        var next = index + 1
        guard next < source.length, isSpace(source.character(at: next)) else { return false }
        while next < source.length, isSpace(source.character(at: next)) {
            next += 1
            work += 1
        }
        guard next < source.length, isUppercase(source.character(at: next)) else { return false }
        var wordStart = index
        while wordStart > 0, isLetter(source.character(at: wordStart - 1)) {
            wordStart -= 1
            work += 1
        }
        let word = source.substring(with: NSRange(location: wordStart, length: index - wordStart)).lowercased()
        return word.count > 1 && !abbreviations.contains(word)
    }

    /// Words whose period does not end a sentence: titles, company and measure abbreviations,
    /// and abbreviated months.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "etc", "vs",
        "gov", "sen", "rep", "gen", "col", "capt", "lt", "sgt", "rev", "hon", "mt", "ft",
        "inc", "co", "ltd", "corp", "dept", "no", "approx",
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0xA0
    }

    private static func isLetter(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit).map { $0.properties.isAlphabetic } ?? false
    }

    private static func isUppercase(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit).map { $0.properties.isUppercase } ?? false
    }

    private static func sentencePrefix(_ before: String) -> String {
        let start = before.lastIndex(where: { ".!?\n".contains($0) }).map { before.index(after: $0) } ?? before.startIndex
        return String(before[start...])
    }

    /// "Today" or "Last Week" capitalized in the middle of a sentence is a name or title.
    private static func isCapitalizedMidSentence(
        _ range: NSRange,
        in source: NSString,
        before: String,
        work: inout Int
    ) -> Bool {
        let first = source.substring(with: NSRange(location: range.location, length: 1))
        guard first != first.lowercased() else { return false }
        work += before.utf16.count
        guard let previous = before.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return !".!?:;\"“”(\n".contains(previous) && !before.hasSuffix("\n")
    }

    /// An absolute date in the same sentence, close to the phrase, already says when.
    private static func hasAbsoluteDateNearby(before: String, after: String, work: inout Int) -> Bool {
        guard let absoluteDateRegex else { return false }
        // The sentence-end scan of `after` and the sentence-start scan of `before`.
        work += after.utf16.count + before.utf16.count
        let sentenceEnd = after.firstIndex(where: { ".!?\n".contains($0) }) ?? after.endIndex
        let afterWindow = String(after[..<sentenceEnd].prefix(40))
        let beforeWindow = String(sentencePrefix(before).suffix(25))
        // Every absolute date pattern has a digit.
        for window in [afterWindow, beforeWindow] where window.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) {
            let range = NSRange(location: 0, length: (window as NSString).length)
            work += range.length
            if absoluteDateRegex.firstMatch(in: window, range: range) != nil { return true }
        }
        return false
    }

    /// Locations between straight double quotes, or between “ and ”.
    private static func quotedLocations(in source: NSString) -> IndexSet {
        var locations = IndexSet()
        var straightStart: Int?
        var curlyStart: Int?
        for index in 0..<source.length {
            switch source.character(at: index) {
            case 0x22:
                if let start = straightStart {
                    locations.insert(integersIn: start..<index)
                    straightStart = nil
                } else {
                    straightStart = index
                }
            case 0x201C:
                curlyStart = index
            case 0x201D:
                if let start = curlyStart {
                    locations.insert(integersIn: start..<index)
                    curlyStart = nil
                }
            default:
                break
            }
        }
        return locations
    }

    // MARK: - Formatting

    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    static func format(_ day: ObservedDay) -> String {
        "\(day.day) \(monthAbbreviations[day.month - 1]) \(day.year)"
    }

    static func formatMonth(year: Int, month: Int) -> String {
        "\(monthNames[month - 1]) \(year)"
    }

    static func formatWeek(startingOn monday: ObservedDay) -> String {
        formatRange(monday, monday.adding(days: 6))
    }

    static func formatRange(_ start: ObservedDay, _ end: ObservedDay) -> String {
        if start.year != end.year { return "\(format(start))–\(format(end))" }
        if start.month != end.month {
            return "\(start.day) \(monthAbbreviations[start.month - 1])–\(format(end))"
        }
        return "\(start.day)–\(format(end))"
    }

    // MARK: - Words

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    private static func amount(_ word: String) -> Int? {
        let value = Int(word) ?? numberWords[word]
        guard let value, value >= 1 else { return nil }
        return value
    }

    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static func isoWeekday(_ word: String) -> Int? {
        weekdays.firstIndex(of: word).map { $0 + 1 }
    }

    // MARK: - Patterns

    private static let phraseRegex: NSRegularExpression? = {
        let number = "\\d{1,3}|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
        let weekday = weekdays.joined(separator: "|")
        let alternatives = [
            "(?<before>(?:the\\s+)?day\\s+before\\s+yesterday)",
            "(?<after>(?:the\\s+)?day\\s+after\\s+tomorrow)",
            "(?<yesterday>yesterday)",
            "(?<lastnight>last\\s+night)",
            "(?<today>today|tonight|this\\s+(?:morning|afternoon|evening))",
            "(?<tomorrow>tomorrow)",
            // Not the tail of "3.5", "2,500", "1 500", "2–3" or "twenty-two".
            "(?<![\\d.,\\-–—‑−/])(?<!\\d\\s)(?<agoN>\(number))\\s+(?<agoUnit>day|week|month|year)s?\\s+ago",
            "this\\s+coming\\s+(?<coming>\(weekday))",
            "last\\s+(?<lastwd>\(weekday))",
            "(?<rel>last|this|next)\\s+(?<relUnit>weekend|week|month|year)",
        ]
        return try? NSRegularExpression(
            pattern: "\\b(?:" + alternatives.joined(separator: "|") + ")\\b",
            options: [.caseInsensitive]
        )
    }()

    private static let ofRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^\\s+of\\b",
        options: [.caseInsensitive]
    )

    /// A reporting verb, with "had" or "'d" before it when there is one, so a match starts
    /// at the pluperfect's backshift.
    private static let reportingVerbRegex: NSRegularExpression? = {
        let verbs = "said|told|wrote|texted|messaged|emailed|promised|mentioned|asked|replied|explained|claimed"
        return try? NSRegularExpression(
            pattern: "(?:(?:\\bhad|['’]d)\\s+)?\\b(?:\(verbs))\\b",
            options: [.caseInsensitive]
        )
    }()

    /// A backshift marker: would, 'd, was/were going to, had.
    private static let backshiftRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bwould\\b|['’]d\\b|\\b(?:was|were)\\s+going\\s+to\\b|\\bhad\\b",
        options: [.caseInsensitive]
    )

    private static let absoluteDateRegex: NSRegularExpression? = {
        let month = "(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?"
        let alternatives = [
            "\(month)\\s+\\d{1,2}\\b",
            "\\b\\d{1,2}(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(month)",
            "\\bthe\\s+\\d{1,2}(?:st|nd|rd|th)\\b",
            "\\b(?:19|20)\\d{2}\\b",
            "\\b\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?\\b",
        ]
        return try? NSRegularExpression(
            pattern: "\\b(?:" + alternatives.joined(separator: "|") + ")",
            options: [.caseInsensitive]
        )
    }()
}

/// Metadata Wax records when it annotates a text, so the original can be rebuilt.
package enum RelativeDateMetadata {
    /// The day the phrases were resolved against, `yyyy-MM-dd`.
    package static let observedDayKey = "wax.relative_dates.observed"
    /// `<original UTF-8 length>:<offset>+<length>,…`: the inserted bytes, as offsets into the
    /// annotated text.
    package static let insertionsKey = "wax.relative_dates.insertions"

    package static func entries(
        for result: RelativeDateAnnotator.Result,
        originalText: String,
        observedDay: ObservedDay
    ) -> [String: String] {
        guard !result.insertions.isEmpty else { return [:] }
        let spans = result.insertions.map { "\($0.utf8Offset)+\($0.utf8Length)" }.joined(separator: ",")
        return [
            observedDayKey: observedDay.iso8601,
            insertionsKey: "\(originalText.utf8.count):\(spans)",
        ]
    }

    /// The text before annotation; `nil` when `text` is not the whole annotated text these
    /// insertions describe (a chunk of it, or text edited after saving), or when the metadata
    /// is malformed.
    package static func originalText(_ text: String, metadata: [String: String]) -> String? {
        guard let encoded = metadata[insertionsKey] else { return text }
        guard let (originalLength, spans) = decodeInsertions(encoded) else { return nil }
        let bytes = Array(text.utf8)
        var expectedLength = originalLength
        for span in spans {
            let (sum, overflow) = expectedLength.addingReportingOverflow(span.length)
            guard !overflow else { return nil }
            expectedLength = sum
        }
        guard bytes.count == expectedLength else { return nil }
        var kept: [UInt8] = []
        kept.reserveCapacity(originalLength)
        var cursor = 0
        for span in spans {
            // Each span is " (…)", at least 3 bytes, inside the text and after the previous one.
            guard span.offset >= cursor, span.offset <= bytes.count - span.length,
                  bytes[span.offset] == UInt8(ascii: " "),
                  bytes[span.offset + 1] == UInt8(ascii: "("),
                  bytes[span.offset + span.length - 1] == UInt8(ascii: ")") else {
                return nil
            }
            kept += bytes[cursor..<span.offset]
            cursor = span.offset + span.length
        }
        kept += bytes[cursor...]
        return String(bytes: kept, encoding: .utf8)
    }

    private static func decodeInsertions(_ encoded: String) -> (Int, [(offset: Int, length: Int)])? {
        let parts = encoded.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let originalLength = Int(parts[0]), originalLength >= 0 else { return nil }
        var spans: [(offset: Int, length: Int)] = []
        for item in parts[1].split(separator: ",") {
            let pair = item.split(separator: "+")
            guard pair.count == 2, let offset = Int(pair[0]), let length = Int(pair[1]),
                  offset >= 0, length >= 3 else { return nil }
            spans.append((offset, length))
        }
        return (originalLength, spans)
    }

    /// The text and metadata to store: annotated when relative phrases resolve against the
    /// caller's `wax.observed_at` day, unchanged otherwise, and always unchanged without one.
    ///
    /// - Throws: `WaxError.io` when `wax.observed_at` is not an ISO 8601 date.
    package static func prepare(
        _ text: String,
        metadata: [String: String]
    ) throws -> (text: String, metadata: [String: String]) {
        // No observation day: nothing to resolve against. Already annotated: saved again with
        // the metadata it was stored with.
        guard let raw = metadata[Memory.RelativeDates.observedAtKey],
              metadata[insertionsKey] == nil else { return (text, metadata) }
        guard let observedDay = ObservedDay(iso8601: raw) else {
            throw WaxError.io("\(Memory.RelativeDates.observedAtKey) must be an ISO 8601 date (yyyy-MM-dd), got \(raw)")
        }
        let result = RelativeDateAnnotator(observedDay: observedDay).annotate(text)
        guard !result.insertions.isEmpty else { return (text, metadata) }
        let added = entries(for: result, originalText: text, observedDay: observedDay)
        return (result.text, metadata.merging(added) { _, new in new })
    }
}
