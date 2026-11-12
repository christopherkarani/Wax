import Testing
@testable import Wax

@Test func walBudgetRangesKeepEachRangeWithinBudget() {
    let ranges = MemoryOrchestrator.walBudgetRanges(itemBytes: [40, 40, 40, 90, 10, 200, 5], budget: 100)
    #expect(ranges == [0..<2, 2..<3, 3..<5, 5..<6, 6..<7])
}

@Test func walBudgetRangesKeepEverythingInOneRangeUnderBudget() {
    #expect(MemoryOrchestrator.walBudgetRanges(itemBytes: [1, 2, 3], budget: 100) == [0..<3])
    #expect(MemoryOrchestrator.walBudgetRanges(itemBytes: [], budget: 100).isEmpty)
}
