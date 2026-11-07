#if canImport(WaxVectorSearchE5) && canImport(CoreML)
import CoreML
import Foundation
import Testing
import WaxCore
@_spi(Testing) @testable import WaxVectorSearchE5

@available(macOS 15.0, iOS 18.0, *)
@Test func e5DefaultsToCPUComputeUnitsUnlessConfigured() {
    let defaults = E5Embedder.resolveComputeUnitsOrder(explicit: [], tuning: CommandLineEmbedderRuntimeTuning())
    #expect(defaults == [.cpuOnly])

    let customized = CommandLineEmbedderRuntimeTuning(computeUnitsOrder: [.cpuAndNeuralEngine])
    #expect(E5Embedder.resolveComputeUnitsOrder(explicit: [], tuning: customized) == [.cpuAndNeuralEngine])
    #expect(E5Embedder.resolveComputeUnitsOrder(explicit: [.all], tuning: customized) == [.all])
}

/// A cpuAndGPU load of the bundled model spends minutes in MPSGraph shape solving (range input
/// shapes), so it is refused up front. The timeout is a hang guard, not a latency budget.
@available(macOS 15.0, iOS 18.0, *)
@Test func e5RejectsCPUAndGPUComputeUnitsInsteadOfStalling() async {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    do {
        _ = try await E5Embeddings.make(configuration: configuration, timeout: .seconds(60))
        Issue.record("expected the cpuAndGPU load to be refused")
    } catch E5Embeddings.InitError.unsupportedComputeUnits {
    } catch {
        Issue.record("expected unsupportedComputeUnits, got \(error)")
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test(arguments: [Float.nan, .infinity, -.infinity])
func e5DecodingRejectsNonFiniteValues(value: Float) throws {
    let array = try MLMultiArray(shape: [1, 4], dataType: .float32)
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    ptr[0] = 0.5
    ptr[1] = value
    ptr[2] = 0.5
    ptr[3] = 0.5

    #expect(throws: E5Embeddings.OutputError.nonFiniteValue) {
        try E5Embeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 4)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func e5DecodingRejectsTokenEmbeddingShapedOutput() throws {
    let array = try MLMultiArray(shape: [1, 3, 4], dataType: .float32)
    #expect(throws: E5Embeddings.OutputError.unexpectedShape(shape: [1, 3, 4], batchSize: 1, outputDimension: 4)) {
        try E5Embeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 4)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func e5DecodingReadsFiniteRows() throws {
    let array = try MLMultiArray(shape: [2, 2], dataType: .float32)
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    for index in 0..<4 {
        ptr[index] = Float(index)
    }
    let decoded = try E5Embeddings._decodeEmbeddingsForTesting(array, batchSize: 2, outputDimension: 2)
    #expect(decoded == [[0, 1], [2, 3]])
}

@available(macOS 15.0, iOS 18.0, *)
@Test func e5BatchPlanningUsesOnlySupportedCoreMLBatchShapes() {
    let plannedSizes = E5Embedder._planBatchSizesForTesting(totalCount: 129, maxBatchSize: 256)
    #expect(plannedSizes == [64, 64, 1])
}

@available(macOS 15.0, iOS 18.0, *)
@Test func e5ReportsMissingModelResource() {
    #expect(throws: E5Embeddings.InitError.self) {
        _ = try E5Embeddings(configuration: nil, overrides: .missingModel)
    }
}

#endif
