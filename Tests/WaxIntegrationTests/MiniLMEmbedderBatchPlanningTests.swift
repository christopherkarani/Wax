import Testing

#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
@_spi(Testing) import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMEmbedderBatchPlanningRespectsMaxBatchSize() {
    let totalCount = 100
    let maxBatchSize = 4
    let plannedSizes = MiniLMEmbedder._planBatchSizesForTesting(
        totalCount: totalCount,
        maxBatchSize: maxBatchSize
    )

    #expect(!plannedSizes.isEmpty)
    #expect(plannedSizes.allSatisfy { size in size > 0 })
    #expect(plannedSizes.allSatisfy { size in size <= maxBatchSize })
    #expect(plannedSizes.reduce(0, +) == totalCount)
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMEmbedderBatchPlanningClampsNonPositiveMaxToOne() {
    let totalCount = 3
    let maxBatchSize = 0
    let plannedSizes = MiniLMEmbedder._planBatchSizesForTesting(
        totalCount: totalCount,
        maxBatchSize: maxBatchSize
    )

    #expect(plannedSizes == [1, 1, 1])
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMEmbedderBatchPlanningUsesSingleBatchWhenPossible() {
    let totalCount = 5
    let maxBatchSize = 8
    let plannedSizes = MiniLMEmbedder._planBatchSizesForTesting(
        totalCount: totalCount,
        maxBatchSize: maxBatchSize
    )

    #expect(plannedSizes == [totalCount])
}
#endif
