#if canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import Testing
import WaxCore
@testable import WaxVectorSearchMiniLM

/// Starvation-proof margins: the timeout must fire before a stuck `Thread.sleep`
/// load returns, even when the timeout task is delayed by suite-wide MiniLM load.
/// `AsyncTimeout` resumes on timeout without waiting for the blocking sleep, so
/// wall-clock test time stays near the timeout (well under 3s), not the delay.
@Suite("MiniLMInitTimeoutTests", .serialized)
struct MiniLMInitTimeoutTests {
    private static let blockedLoadDelay: Duration = .seconds(10)
    private static let initTimeout: Duration = .milliseconds(500)

    @available(macOS 15.0, iOS 18.0, *)
    @Test
    func miniLMEmbeddingsMakeTimesOutWhenModelLoadBlocks() async throws {
        var overrides = MiniLMEmbeddings.Overrides.missingModel
        overrides.blockingModelLoadDelay = Self.blockedLoadDelay

        await #expect(throws: AsyncTimeout.TimeoutError.self) {
            _ = try await MiniLMEmbeddings.make(
                overrides: overrides,
                timeout: Self.initTimeout
            )
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test
    func miniLMEmbedderMakeTimesOutWhenModelLoadBlocks() async throws {
        var overrides = MiniLMEmbeddings.Overrides.missingModel
        overrides.blockingModelLoadDelay = Self.blockedLoadDelay

        await #expect(throws: AsyncTimeout.TimeoutError.self) {
            _ = try await MiniLMEmbedder.make(
                overrides: overrides,
                timeout: Self.initTimeout
            )
        }
    }
}
#endif
