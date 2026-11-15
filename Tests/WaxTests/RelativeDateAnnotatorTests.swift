import Foundation
import Testing
@testable import Wax

/// Tuesday 22 August 2023: its ISO week runs Monday 21 – Sunday 27 August.
private let tuesday = ObservedDay(year: 2023, month: 8, day: 22)

private func annotated(_ text: String, on day: ObservedDay = tuesday) -> String {
    RelativeDateAnnotator(observedDay: day).annotate(text).text
}

// MARK: - Day phrases

@Test(arguments: [
    ("I went yesterday.", "I went yesterday (21 Aug 2023)."),
    ("Yesterday I went.", "Yesterday (21 Aug 2023) I went."),
    ("We talked last night", "We talked last night (21 Aug 2023)"),
    ("It is due today", "It is due today (22 Aug 2023)"),
    ("Dinner is tonight.", "Dinner is tonight (22 Aug 2023)."),
    ("I ran this morning", "I ran this morning (22 Aug 2023)"),
    ("Call me this evening", "Call me this evening (22 Aug 2023)"),
    ("See you tomorrow!", "See you tomorrow (23 Aug 2023)!"),
    ("It shipped the day before yesterday", "It shipped the day before yesterday (20 Aug 2023)"),
    ("It ships the day after tomorrow", "It ships the day after tomorrow (24 Aug 2023)"),
])
func annotatesDayPhrases(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

@Test(arguments: [
    ("I moved 3 days ago", "I moved 3 days ago (19 Aug 2023)"),
    ("I moved a day ago", "I moved a day ago (21 Aug 2023)"),
    ("I moved ten days ago", "I moved ten days ago (12 Aug 2023)"),
])
func annotatesDaysAgo(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

// MARK: - Weekdays

@Test(arguments: [
    ("I saw her last Friday", "I saw her last Friday (18 Aug 2023)"),
    // Said on a Tuesday, "last Tuesday" is a week back, never today.
    ("I saw her last Tuesday", "I saw her last Tuesday (15 Aug 2023)"),
    ("I saw her last Monday", "I saw her last Monday (21 Aug 2023)"),
    ("The party is this coming Friday", "The party is this coming Friday (25 Aug 2023)"),
])
func annotatesWeekdays(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

// MARK: - Weeks, weekends, months, years

@Test(arguments: [
    ("I was sick last week", "I was sick last week (14–20 Aug 2023)"),
    ("I am busy this week", "I am busy this week (21–27 Aug 2023)"),
    ("I fly out next week", "I fly out next week (28 Aug–3 Sep 2023)"),
    ("I moved two weeks ago", "I moved two weeks ago (7–13 Aug 2023)"),
    ("I moved a week ago", "I moved a week ago (14–20 Aug 2023)"),
    ("We hiked last weekend", "We hiked last weekend (19–20 Aug 2023)"),
    ("We hike this weekend", "We hike this weekend (26–27 Aug 2023)"),
    ("I started last month", "I started last month (July 2023)"),
    ("It is quiet this month", "It is quiet this month (August 2023)"),
    ("It opens next month", "It opens next month (September 2023)"),
    ("I started 3 months ago", "I started 3 months ago (May 2023)"),
    ("I graduated last year", "I graduated last year (2022)"),
    ("It is a good year this year", "It is a good year this year (2023)"),
    ("I retire next year", "I retire next year (2024)"),
    ("I met him five years ago", "I met him five years ago (2018)"),
    ("I met him a year ago", "I met him a year ago (2022)"),
])
func annotatesPeriods(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

@Test
func weekRangesCrossYearBoundaries() {
    // Tuesday 3 January 2023: the previous ISO week is 26 Dec 2022 – 1 Jan 2023.
    let day = ObservedDay(year: 2023, month: 1, day: 3)
    #expect(annotated("I was away last week", on: day) == "I was away last week (26 Dec 2022–1 Jan 2023)")
}

@Test
func monthsAgoCrossYearBoundaries() {
    let day = ObservedDay(year: 2023, month: 2, day: 10)
    #expect(annotated("I joined 3 months ago", on: day) == "I joined 3 months ago (November 2022)")
}

@Test
func annotatesEveryPhraseInOneText() {
    let text = "Yesterday I called; last week I wrote. See you tomorrow."
    #expect(annotated(text) == "Yesterday (21 Aug 2023) I called; last week (14–20 Aug 2023) I wrote. See you tomorrow (23 Aug 2023).")
}

// MARK: - Left alone

@Test(arguments: [
    // Possessive: the phrase names a thing ("last week's report"), not when the sentence happened.
    "last week's report was late",
    "Yesterday’s news is old",
    "today's plan is simple",
    // Quoted speech keeps its own time frame.
    "She told me \"I saw it yesterday\" at lunch",
    "He wrote “see you tomorrow” on the card",
    // Already absolute.
    "I went yesterday (21 Aug 2023) to the shop",
    "Yesterday, August 21, I went",
    "I saw her last Friday, 18 Aug",
    "I graduated last year, in 2022",
    "It was due yesterday, 8/21",
    // "the last week" is the past seven days, not the previous calendar week.
    "the last week has been hard",
    "the last Friday of the month",
    "every last Friday",
    "last Friday of every month",
    // Ambiguous in English usage.
    "Let's meet next Friday",
    "Let's meet this Friday",
    "We hike next weekend",
    "I finished it in two days",
    "I will be there in a week",
    // Vague amounts.
    "I moved a few days ago",
    "I moved a couple of weeks ago",
    "I saw him the other day",
    "I moved recently",
    // Names and titles, capitalized mid-sentence.
    "I watched the Today show",
    "I read USA Today every day",
    // Compounds.
    "a last-minute change",
    "a to-do for tonight-ish plans",
])
func leavesTextAlone(text: String) {
    #expect(annotated(text) == text)
}

@Test
func lastWeekendIsAmbiguousOnAWeekend() {
    let saturday = ObservedDay(year: 2023, month: 8, day: 26)
    #expect(annotated("We hiked last weekend", on: saturday) == "We hiked last weekend")
}

@Test
func leavesTextWithoutPhrasesByteIdentical() {
    let text = "Plain notes about apples, cafés and 🍎 with no dates."
    let result = RelativeDateAnnotator(observedDay: tuesday).annotate(text)
    #expect(result.text == text)
    #expect(result.insertions.isEmpty)
}

@Test
func annotatingTwiceChangesNothing() {
    let once = annotated("Yesterday I called and last month I wrote.")
    #expect(annotated(once) == once)
}

// MARK: - Recovering the original

@Test
func insertionsRecoverTheOriginalExactly() {
    let original = "Café ☕️ yesterday; 🍎 last week, and “quoted tomorrow” stays."
    let result = RelativeDateAnnotator(observedDay: tuesday).annotate(original)
    #expect(result.text != original)
    let metadata = RelativeDateMetadata.entries(for: result, originalText: original, observedDay: tuesday)
    #expect(Memory.RelativeDates.originalText(result.text, metadata: metadata) == original)
}

@Test
func originalTextIsNilForTextThatDoesNotMatchTheInsertions() {
    let original = "I went yesterday and came back."
    let result = RelativeDateAnnotator(observedDay: tuesday).annotate(original)
    let metadata = RelativeDateMetadata.entries(for: result, originalText: original, observedDay: tuesday)
    // A chunk of the document, or text edited after saving.
    #expect(Memory.RelativeDates.originalText("I went yesterday", metadata: metadata) == nil)
}

@Test
func originalTextOfUnannotatedTextIsTheText() {
    #expect(Memory.RelativeDates.originalText("no dates here", metadata: [:]) == "no dates here")
}

// MARK: - Observation dates

@Test(arguments: [
    ("2023-08-22", ObservedDay(year: 2023, month: 8, day: 22)),
    ("2023-08-22T23:30:00-07:00", ObservedDay(year: 2023, month: 8, day: 22)),
    ("2023-08-22T01:00:00Z", ObservedDay(year: 2023, month: 8, day: 22)),
])
func parsesObservationDates(raw: String, expected: ObservedDay) {
    #expect(ObservedDay(iso8601: raw) == expected)
}

@Test(arguments: ["Aug 22 2023", "2023-13-01", "2023-02-30", "22/08/2023", ""])
func rejectsMalformedObservationDates(raw: String) {
    #expect(ObservedDay(iso8601: raw) == nil)
}
