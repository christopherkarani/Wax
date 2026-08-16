import Foundation
import Testing
@testable import Wax

@Test func fromClosedDateRangeNilPassthrough() {
    #expect(SearchTimeRange.fromClosedDateRange(nil) == nil)
}

@Test func fromClosedDateRangeConvertsInclusiveBoundsToExclusiveBefore() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = Date(timeIntervalSince1970: 1_700_000_100)
    let range = try #require(SearchTimeRange.fromClosedDateRange(start...end))

    #expect(range.after == 1_700_000_000_000)
    #expect(range.before == 1_700_000_100_000 + 1)
    #expect(range.contains(1_700_000_000_000))
    #expect(range.contains(1_700_000_100_000))
    #expect(!range.contains(1_700_000_100_000 + 1))
}

@Test func fromClosedDateRangeDistantFutureKeepsFiniteExclusiveBefore() {
    let start = Date(timeIntervalSince1970: 0)
    let range = try #require(SearchTimeRange.fromClosedDateRange(start...Date.distantFuture))
    let beforeInclusive = Int64(Date.distantFuture.timeIntervalSince1970 * 1000)

    #expect(range.after == 0)
    #expect(beforeInclusive < Int64.max)
    #expect(range.before == beforeInclusive + 1)
}

@Test func fromClosedMillisecondBoundsSaturatedUpperBoundIsUnbounded() {
    let range = SearchTimeRange.fromClosedMillisecondBounds(
        after: 1_700_000_000_000,
        beforeInclusive: Int64.max
    )
    #expect(range.before == nil)
    #expect(range.contains(Int64.max))
    // Old Int64.max exclusive sentinel excluded the saturated timestamp itself.
    #expect(SearchTimeRange(after: 0, before: Int64.max).contains(Int64.max) == false)
}
