import Testing

#if canImport(WaxVectorSearchArctic) && canImport(CoreML)
@testable import WaxVectorSearchArctic

@available(macOS 15.0, iOS 18.0, *)
@Test func arcticEmbedderBatchPlanningUsesOnlySupportedCoreMLBatchShapes() {
    let plannedSizes = ArcticEmbedder._planBatchSizesForTesting(
        totalCount: 129,
        maxBatchSize: 256
    )

    #expect(plannedSizes == [64, 64, 1])
    #expect(plannedSizes.allSatisfy { $0 <= 64 })
}
#endif
