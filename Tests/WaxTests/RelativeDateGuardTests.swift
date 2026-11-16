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
    // "her" and "that" can also be objects ("I saw her last Friday"); left alone either way.
    "I saw her last Friday.",
    "I did that last week.",
])
func leavesLastMeaningFinalAlone(text: String) {
    #expect(annotated(text) == text)
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
])
func leavesMovedAnchorsAlone(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

// MARK: - Reported speech

@Test(arguments: [
    ("He said yesterday that he would come tomorrow.", "He said yesterday (21 Aug 2023) that he would come tomorrow."),
    ("Last Monday she said she would finish it today.", "Last Monday (21 Aug 2023) she said she would finish it today."),
    ("She told me she was busy tonight.", "She told me she was busy tonight."),
    ("He promised to call this evening.", "He promised to call this evening."),
    ("Three days ago he wrote that he lands tomorrow.", "Three days ago (19 Aug 2023) he wrote that he lands tomorrow."),
])
func leavesReportedTimesAlone(input: String, expected: String) {
    #expect(annotated(input) == expected)
}

@Test
func reportedSpeechEndsAtTheSentence() {
    #expect(annotated("He said so. I leave tomorrow.") == "He said so. I leave tomorrow (23 Aug 2023).")
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

@Test
func annotatesManyPhrasesInLinearTime() {
    let text = String(repeating: "and yesterday ", count: 16_000)
    let clock = ContinuousClock()
    var insertions = 0
    let elapsed = clock.measure {
        insertions = RelativeDateAnnotator(observedDay: tuesday).annotate(text).insertions.count
    }
    #expect(insertions == 16_000)
    #expect(elapsed < .seconds(1), "took \(elapsed)")
}

@Test
func blockedPhrasesInLongUnpunctuatedTextAreCheap() {
    let text = String(repeating: "the yesterday ", count: 16_000)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        _ = RelativeDateAnnotator(observedDay: tuesday).annotate(text)
    }
    #expect(elapsed < .seconds(1), "took \(elapsed)")
}
