#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import Testing
import WaxCore
@testable import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbeddingsMakeTimesOutWhenModelLoadBlocks() async throws {
    var overrides = MiniLMEmbeddings.Overrides.missingModel
    overrides.blockingModelLoadDelay = .seconds(1)

    await #expect(throws: AsyncTimeout.TimeoutError.self) {
        _ = try await MiniLMEmbeddings.make(
            overrides: overrides,
            timeout: .milliseconds(50)
        )
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbedderMakeTimesOutWhenModelLoadBlocks() async throws {
    var overrides = MiniLMEmbeddings.Overrides.missingModel
    overrides.blockingModelLoadDelay = .seconds(1)

    await #expect(throws: AsyncTimeout.TimeoutError.self) {
        _ = try await MiniLMEmbedder.make(
            overrides: overrides,
            timeout: .milliseconds(50)
        )
    }
}
#endif
