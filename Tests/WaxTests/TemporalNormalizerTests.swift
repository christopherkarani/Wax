import Foundation
import Testing
@testable import Wax

@Test
func resolvesToday() throws {
    let anchor = Date(timeIntervalSince1970: 1_740_000_000)
    let normalizer = TemporalNormalizer(anchor: anchor)
    let result = try normalizer.resolve("today")
    #expect(result.kind == .date)
    let cal = Calendar(identifier: .gregorian)
    #expect(cal.isDate(result.start, inSameDayAs: anchor))
}

@Test
func resolvesYesterday() throws {
    let anchor = Date(timeIntervalSince1970: 1_740_000_000)
    let normalizer = TemporalNormalizer(anchor: anchor)
    let result = try normalizer.resolve("yesterday")
    let cal = Calendar(identifier: .gregorian)
    let expected = cal.date(byAdding: .day, value: -1, to: anchor)!
    #expect(cal.isDate(result.start, inSameDayAs: expected))
}

@Test
func resolvesLastWeek() throws {
    let anchor = Date(timeIntervalSince1970: 1_740_000_000)
    let normalizer = TemporalNormalizer(anchor: anchor)
    let result = try normalizer.resolve("last week")
    #expect(result.kind == .range)
    #expect(result.end != nil)
    #expect(result.start < anchor)
    #expect(result.end! < anchor)
}

@Test
func resolvesRelativeDays() throws {
    let anchor = Date(timeIntervalSince1970: 1_740_000_000)
    let normalizer = TemporalNormalizer(anchor: anchor)

    let inThree = try normalizer.resolve("in 3 days")
    let cal = Calendar(identifier: .gregorian)
    let expected = cal.date(byAdding: .day, value: 3, to: anchor)!
    #expect(cal.isDate(inThree.start, inSameDayAs: expected))

    let twoAgo = try normalizer.resolve("2 days ago")
    let expectedAgo = cal.date(byAdding: .day, value: -2, to: anchor)!
    #expect(cal.isDate(twoAgo.start, inSameDayAs: expectedAgo))
}

@Test
func resolvesRelativeWeeks() throws {
    let anchor = Date(timeIntervalSince1970: 1_740_000_000)
    let normalizer = TemporalNormalizer(anchor: anchor)

    let inTwo = try normalizer.resolve("in 2 weeks")
    let cal = Calendar(identifier: .gregorian)
    let expected = cal.date(byAdding: .weekOfYear, value: 2, to: anchor)!
    #expect(cal.isDate(inTwo.start, inSameDayAs: expected))

    let oneAgo = try normalizer.resolve("1 weeks ago")
    let expectedAgo = cal.date(byAdding: .weekOfYear, value: -1, to: anchor)!
    #expect(cal.isDate(oneAgo.start, inSameDayAs: expectedAgo))
}

@Test
func resolvesLastFriday() throws {
    let anchor = Date(timeIntervalSince1970: 1_740_000_000)
    let normalizer = TemporalNormalizer(anchor: anchor)
    let result = try normalizer.resolve("last friday")
    let cal = Calendar(identifier: .gregorian)
    let weekday = cal.component(.weekday, from: result.start)
    #expect(weekday == 6)
    #expect(result.start < anchor)
}

@Test
func resolvesQuarter() throws {
    let normalizer = TemporalNormalizer(anchor: Date())
    let result = try normalizer.resolve("q3 2025")
    #expect(result.kind == .range)
    #expect(result.end != nil)
    let cal = Calendar(identifier: .gregorian)
    #expect(cal.component(.month, from: result.start) == 7)
    #expect(cal.component(.month, from: result.end!) == 10)
}

@Test
func unsupportedPhraseThrows() {
    let normalizer = TemporalNormalizer(anchor: Date())
    #expect(throws: WaxError.self) {
        _ = try normalizer.resolve("the heat death of the universe")
    }
}

@Test
func temporalLookingButUnsupportedDoesNotResolve() {
    let normalizer = TemporalNormalizer(anchor: Date())
    #expect(throws: WaxError.self) {
        _ = try normalizer.resolve("timeline architecture")
    }
}
