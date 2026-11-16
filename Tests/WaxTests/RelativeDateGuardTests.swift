import Foundation
import Testing
@testable import Wax

/// Tuesday 22 August 2023.
private let tuesday = ObservedDay(year: 2023, month: 8, day: 22)

private func annotated(_ text: String, on day: ObservedDay = tuesday) -> String {
    RelativeDateAnnotator(observedDay: day).annotate(text).text
}

// MARK: - "last" meaning "final"

@Test(arguments: [
    "This is my last week at Acme.",
    "Our last night in Rome was great.",
    "It was her last year at school.",
    "That was my last Friday at the office.",
    "his last month in Paris was fun",
    "their last weekend together",
    "whose last year was that",
    "I loved those last weeks",
    "the first and final last week",
    "It was our second last night there.",
    // "her", "that", "this": possessive or object; only a past verb plus a clause end settles it.
    "I saw her last week at the gym",
    "We celebrated her last night.",
    "It was her last week.",
    "I missed her last Friday.",
])
func leavesLastMeaningFinalAlone(text: String) {
    #expect(annotated(text) == text)
}

@Test(arguments: [
    ("I saw her last Friday.", "I saw her last Friday (18 Aug 2023)."),
    ("I did that last week.", "I did that last week (14–20 Aug 2023)."),
    ("We fixed this last month, and it held.", "We fixed this last month (July 2023), and it held."),
    ("I called her last night but she slept", "I called her last night (21 Aug 2023) but she slept"),
    ("I met her last year", "I met her last year (2022)"),
])
func annotatesLastAfterAnObjectOfAPastVerb(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

@Test(arguments: [
    "My next week off is in October.",
    "Our next year at school",
    "That next week we moved in.",
    "their next month abroad",
])
func leavesNextAfterAPossessiveAlone(text: String) {
    #expect(annotated(text) == text)
}

@Test
func annotatesNextAfterHer() {
    #expect(annotated("I will see her next week.") == "I will see her next week (28 Aug–3 Sep 2023).")
}

@Test
func stillAnnotatesThatBeforeYesterday() {
    #expect(annotated("I learned that yesterday.") == "I learned that yesterday (21 Aug 2023).")
}

// MARK: - Numbers that are part of a larger amount

@Test(arguments: [
    "That was twenty-two years ago.",
    "That was twenty five years ago.",
    "It was thirty-one days ago.",
    "It happened 3.5 years ago.",
    "It was built 2,500 years ago.",
    "I left 2-3 weeks ago.",
    "I left two or three weeks ago.",
    "It was a hundred and two years ago.",
    "It was one hundred years ago.",
    "It was two thousand years ago.",
    "It was two to three weeks ago.",
    "It was 2 to 3 days ago.",
    "It was 2 through 4 days ago.",
    "I left 2–3 weeks ago.",
    "I left 2—3 weeks ago.",
    "I left 2/3 weeks ago.",
    "It was built 1 500 years ago.",
])
func leavesPartsOfLargerAmountsAlone(text: String) {
    #expect(annotated(text) == text)
}

// MARK: - Vague amounts

@Test(arguments: [
    "I moved more than 3 years ago.",
    "I called less than a week ago.",
    "I quit over a year ago.",
    "It ended under a month ago.",
    "It was almost two years ago.",
    "It was nearly a year ago.",
    "It was about 3 weeks ago.",
    "It was around five years ago.",
    "It was roughly ten days ago.",
    "It was at least a year ago.",
    "It was up to two weeks ago.",
    "It happened within a week ago.",
    "It was fewer than 3 days ago.",
    "It was at most 2 weeks ago.",
    "It was not even a week ago.",
    "It was upwards of 5 years ago.",
    "It was well over a year ago.",
])
func leavesQualifiedAmountsAlone(text: String) {
    #expect(annotated(text) == text)
}

// MARK: - Phrases that move the anchor

@Test(arguments: [
    ("I saw him day before yesterday.", "I saw him day before yesterday (20 Aug 2023)."),
    ("It ships day after tomorrow.", "It ships day after tomorrow (24 Aug 2023)."),
    ("We met a year ago today.", "We met a year ago (2022) today."),
    ("It is due a week from today.", "It is due a week from today."),
    ("I have been sick since yesterday.", "I have been sick since yesterday."),
    ("Two days before yesterday it rained.", "Two days before yesterday it rained."),
    ("The week after tomorrow is free.", "The week after tomorrow is free."),
    ("It was the week before last week.", "It was the week before last week."),
    ("It came two days after last Friday.", "It came two days after last Friday."),
])
func leavesMovedAnchorsAlone(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

// MARK: - Reported speech

@Test(arguments: [
    ("He said yesterday that he would come tomorrow.", "He said yesterday (21 Aug 2023) that he would come tomorrow."),
    ("Last Monday she said she would finish it today.", "Last Monday (21 Aug 2023) she said she would finish it today."),
    ("He said last month that he would come next week.", "He said last month (July 2023) that he would come next week."),
    ("On Monday she texted that she would come tomorrow.", "On Monday she texted that she would come tomorrow."),
    (
        "He said, after a long and rambling explanation about trains, delays and the weather, that he would come tomorrow.",
        "He said, after a long and rambling explanation about trains, delays and the weather, that he would come tomorrow."
    ),
    ("Last Monday she told me she had arrived yesterday.", "Last Monday (21 Aug 2023) she told me she had arrived yesterday."),
    ("She promised she'd call this coming Friday.", "She promised she'd call this coming Friday."),
    ("He wrote that he was going to move next month.", "He wrote that he was going to move next month."),
    // Abbreviation periods do not end the sentence.
    ("She told me Dr. Lee would call tomorrow.", "She told me Dr. Lee would call tomorrow."),
    ("He said Mr. Jones would come next week.", "He said Mr. Jones would come next week."),
    ("He said he would come, e.g. tomorrow.", "He said he would come, e.g. tomorrow."),
    ("She said J. Smith would visit tomorrow.", "She said J. Smith would visit tomorrow."),
    // Pluperfect reports carry the backshift before the verb.
    ("He'd said tomorrow was fine.", "He'd said tomorrow was fine."),
    ("She had promised tomorrow would work.", "She had promised tomorrow would work."),
    ("He’d told me last week was fine.", "He’d told me last week was fine."),
])
func leavesBackshiftedReportedTimesAlone(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

@Test(arguments: [
    ("I worked late last night, so today I am tired.", "I worked late last night (21 Aug 2023), so today (22 Aug 2023) I am tired."),
    ("Last week was busy; today is calm.", "Last week (14–20 Aug 2023) was busy; today (22 Aug 2023) is calm."),
    ("I asked for the day off tomorrow.", "I asked for the day off tomorrow (23 Aug 2023)."),
    ("I told my boss I am out tomorrow.", "I told my boss I am out tomorrow (23 Aug 2023)."),
    ("She told me she was busy tonight.", "She told me she was busy tonight (22 Aug 2023)."),
    ("He said so. He would come tomorrow.", "He said so. He would come tomorrow (23 Aug 2023)."),
    ("He said so! Would you come tomorrow?", "He said so! Would you come tomorrow (23 Aug 2023)?"),
    ("He said tomorrow was fine.", "He said tomorrow (23 Aug 2023) was fine."),
])
func annotatesTimesWithoutABackshift(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

// MARK: - Idempotence for any year

@Test(arguments: [
    ObservedDay(year: 2100, month: 3, day: 1),
    ObservedDay(year: 1850, month: 3, day: 1),
    ObservedDay(year: 12, month: 6, day: 15),
])
func annotatingTwiceChangesNothingInAnyYear(day: ObservedDay) {
    let texts = [
        "I went yesterday.", "I was sick last week.", "I started last month.", "I retire next year.",
        "We hiked last weekend.", "I moved 3 days ago.", "I saw him last Friday.", "Party this coming Friday.",
    ]
    for text in texts {
        let once = annotated(text, on: day)
        #expect(once != text)
        #expect(annotated(once, on: day) == once)
    }
}

// MARK: - Malformed insertion metadata

@Test(arguments: [
    ("a ", "1:1+1"),
    ("ab", "2:0+9223372036854775807"),
    ("ab", "9223372036854775807:0+3,1+3"),
    ("ab", "-1:0+3"),
    ("ab", "2:-5+3"),
    ("ab", "2:"),
    ("ab", "x:0+3"),
    ("ab", "2:0+3+4"),
    ("abcdef", "3:0+3,1+3"),
])
func originalTextIsNilForMalformedInsertions(text: String, encoded: String) {
    #expect(Memory.RelativeDates.originalText(text, metadata: [RelativeDateMetadata.insertionsKey: encoded]) == nil)
}

// MARK: - Observation dates

@Test(arguments: [
    ("2023-08-22T23:30", ObservedDay(year: 2023, month: 8, day: 22)),
    ("2023-08-22T23:30:00.123+05:30", ObservedDay(year: 2023, month: 8, day: 22)),
    ("2023-08-22T23:30:00+0530", ObservedDay(year: 2023, month: 8, day: 22)),
    ("2023-08-22 23:30:00", ObservedDay(year: 2023, month: 8, day: 22)),
    ("2024-02-29", ObservedDay(year: 2024, month: 2, day: 29)),
    ("2023-08-22t23:30:00z", ObservedDay(year: 2023, month: 8, day: 22)),
])
func parsesFullDateTimes(raw: String, expected: ObservedDay) {
    #expect(ObservedDay(iso8601: raw) == expected)
}

@Test(arguments: [
    "2023-08-22 lol", "2023-08-22Tgarbage", "2023-08-22T", " 2023-08-22", "2023-8-22",
    "2023-08-22\n", "２０２３-08-22", "2023-08-22T25:00", "2023-08-22T23:60", "2023-08-22T23:30:61",
    "2023-08-22T23:30:00+25:00", "2023-08-22T23:30:00Zjunk", "2023-08-22T23:30:00.", "2023-02-29",
])
func rejectsTrailingJunkAndInvalidTimes(raw: String) {
    #expect(ObservedDay(iso8601: raw) == nil)
}

@Test
func dateTimesUseTheDateAsWrittenAndTheHelperUsesTheLocalDay() throws {
    // 5 pm PDT on 21 Aug 2023 is midnight UTC on the 22nd.
    let instant = Date(timeIntervalSince1970: 1_692_662_400)
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    #expect(ObservedDay(iso8601: ISO8601DateFormatter().string(from: instant)) == ObservedDay(year: 2023, month: 8, day: 22))
    #expect(Memory.RelativeDates.observedAt(instant, timeZone: losAngeles) == "2023-08-21")
}

// MARK: - Cost

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Linear cost grows about 4× from 2,000 to 8,000 phrases; a per-phrase scan to the sentence
/// boundary grows about 16×. Small and large runs alternate so both see the same load from
/// parallel tests, and each keeps its fastest run, since contention only adds time.
@Test(arguments: ["and yesterday ", "the yesterday ", "he said tomorrow ", "said would tomorrow "])
func annotationTimeGrowsLinearly(phrase: String) {
    let annotator = RelativeDateAnnotator(observedDay: tuesday)
    let smallText = String(repeating: phrase, count: 2_000)
    let largeText = String(repeating: phrase, count: 8_000)
    let clock = ContinuousClock()
    var small = Double.infinity
    var large = Double.infinity
    for _ in 0..<5 {
        small = min(small, seconds(clock.measure { _ = annotator.annotate(smallText) }))
        large = min(large, seconds(clock.measure { _ = annotator.annotate(largeText) }))
    }
    #expect(large / small < 8, "2k \(small) s, 8k \(large) s")
}
