#if canImport(WaxVectorSearchArctic) && canImport(CoreML)
import CoreML
import Foundation
import Testing
import WaxCore
@_spi(Testing) @testable import WaxVectorSearchArctic

@available(macOS 15.0, iOS 18.0, *)
@Test func arcticDefaultsToCPUComputeUnitsUnlessConfigured() {
    let defaults = ArcticEmbedder.resolveComputeUnitsOrder(explicit: [], tuning: CommandLineEmbedderRuntimeTuning())
    #expect(defaults == [.cpuOnly, .cpuAndGPU])

    let customized = CommandLineEmbedderRuntimeTuning(computeUnitsOrder: [.cpuAndNeuralEngine])
    #expect(ArcticEmbedder.resolveComputeUnitsOrder(explicit: [], tuning: customized) == [.cpuAndNeuralEngine])
    #expect(ArcticEmbedder.resolveComputeUnitsOrder(explicit: [.all], tuning: customized) == [.all])
}

@available(macOS 15.0, iOS 18.0, *)
@Test func arcticDecodingRejectsNonFiniteValues() throws {
    let array = try MLMultiArray(shape: [1, 4], dataType: .float32)
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    ptr[0] = 0.5
    ptr[1] = .nan
    ptr[2] = 0.5
    ptr[3] = 0.5

    #expect(throws: ArcticEmbeddings.OutputError.nonFiniteValue) {
        try ArcticEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 4)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func arcticDecodingRejectsTokenEmbeddingShapedOutput() throws {
    let array = try MLMultiArray(shape: [1, 3, 4], dataType: .float32)
    #expect(throws: ArcticEmbeddings.OutputError.unexpectedShape(shape: [1, 3, 4], batchSize: 1, outputDimension: 4)) {
        try ArcticEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 1, outputDimension: 4)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func arcticDecodingReadsFiniteRows() throws {
    let array = try MLMultiArray(shape: [2, 2], dataType: .float32)
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    for index in 0..<4 {
        ptr[index] = Float(index)
    }
    let decoded = try ArcticEmbeddings._decodeEmbeddingsForTesting(array, batchSize: 2, outputDimension: 2)
    #expect(decoded == [[0, 1], [2, 3]])
}

@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_ARCTIC"] != "1",
                 "Set WAX_TEST_ARCTIC=1 to run Arctic Core ML prediction tests"))
struct ArcticPredictionErrorTests {
    @Test
    func predictionErrorsPropagateInsteadOfBecomingNil() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let model = try ArcticEmbeddings()
        // The model accepts sequence lengths 32...512; 16 is outside the flexible shape range.
        let inputIds = try MLMultiArray(shape: [1, 16], dataType: .int32)
        let attentionMask = try MLMultiArray(shape: [1, 16], dataType: .int32)

        await #expect(throws: (any Error).self) {
            _ = try await model._predictForTesting(
                inputIds: inputIds,
                attentionMask: attentionMask,
                batchSize: 1
            )
        }
    }

    @Test
    func embedderReturnsFiniteUnitVectors() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let embedder = try ArcticEmbedder()
        let vectors = try await embedder.embed(batch: ["finite check", "second sentence", "third one"])
        #expect(vectors.count == 3)
        for vector in vectors {
            #expect(vector.count == 384)
            let allFinite = vector.allSatisfy(\.isFinite)
            #expect(allFinite)
        }
    }
}
#endif
