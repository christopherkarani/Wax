#if canImport(WaxVectorSearchMiniLM)
import Foundation
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

#if canImport(Darwin)
/// A Core ML load blocks its thread for the whole load, and a load that times out keeps
/// running. On a cooperative thread it stalls every other task in the process, so the
/// load must run on a GCD thread.
@available(macOS 15.0, iOS 18.0, *)
@Test
func miniLMEmbeddingsMakeLoadsOffTheCooperativePool() async throws {
    let label = LoadQueueLabel()
    var overrides = MiniLMEmbeddings.Overrides.missingModel
    overrides.tokenizerFactory = {
        label.set(String(cString: __dispatch_queue_get_label(nil)))
        throw MiniLMEmbeddings.InitError.tokenizerLoadFailed("load thread recorded")
    }

    await #expect(throws: MiniLMEmbeddings.InitError.self) {
        _ = try await MiniLMEmbeddings.make(overrides: overrides, timeout: .seconds(60))
    }
    let recorded = try #require(label.get())
    #expect(!recorded.contains("cooperative"), "\(recorded)")
}

private final class LoadQueueLabel: @unchecked Sendable {
    private let lock = NSLock()
    private var label: String?
    func set(_ value: String) { lock.withLock { label = value } }
    func get() -> String? { lock.withLock { label } }
}
#endif

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
