import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch
import WaxVectorSearch

private final class CountingVectorEngine: VectorSearchEngine, @unchecked Sendable {
    let dimensions: Int

    init(dimensions: Int) {
        self.dimensions = dimensions
    }

    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        _ = vector
        _ = topK
        return []
    }

    func add(frameId: UInt64, vector: [Float]) async throws {
        _ = frameId
        _ = vector
    }

    func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        _ = frameIds
        _ = vectors
    }

    func remove(frameId: UInt64) async throws {
        _ = frameId
    }

    func stageForCommit(into wax: Wax) async throws {
        _ = wax
    }
}

@Suite(.serialized)
struct EngineStoreLifecycleTests {
    /// AC-004: engines cached by an owner-scoped store are released on
    /// ``releaseEngines`` — proven via injected fakes (instance counters +
    /// reload identity change), not via any process-global registry.
    @Test func engineStore_releaseEnginesDropsInjectedFakesAndReloadsFreshInstances() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            // Pending (uncommitted) embedding so the pendingOnly descriptor resolves.
            let frameId = try await wax.put(Data("alpha".utf8))
            try await wax.putEmbedding(frameId: frameId, vector: [1.0, 0.0])

            let textLoads = Counter()
            let vectorLoads = Counter()
            weak var weakFirstTextEngine: FTS5SearchEngine?
            weak var weakFirstVectorEngine: CountingVectorEngine?

            let engineStore = UnifiedSearchEngineStore(
                textEngineFactory: {
                    await textLoads.increment()
                    return try FTS5SearchEngine.inMemory()
                },
                vectorEngineFactory: { _, _ in
                    await vectorLoads.increment()
                    return CountingVectorEngine(dimensions: 2)
                }
            )

            func request() -> SearchRequest {
                SearchRequest(
                    query: "alpha",
                    embedding: [1.0, 0.0],
                    mode: .hybrid(alpha: 0.5),
                    topK: 5,
                    nowMs: 1_000
                )
            }

            _ = try await wax.search(request(), engineStore: engineStore)
            #expect(await textLoads.value == 1)
            #expect(await vectorLoads.value == 1)
            #expect(await engineStore.cachedEngineCount == 2)

            // Warm repeat: no new loads while keys are unchanged.
            _ = try await wax.search(request(), engineStore: engineStore)
            #expect(await textLoads.value == 1)
            #expect(await vectorLoads.value == 1)

            do {
                let textEngine = try await engineStore.textEngine(for: wax)
                weakFirstTextEngine = textEngine
                let snapshot = try await engineStore.vectorEngine(for: wax, queryEmbeddingDimensions: 2)
                weakFirstVectorEngine = snapshot as? CountingVectorEngine
                #expect(weakFirstTextEngine != nil)
                #expect(weakFirstVectorEngine != nil)
            }

            // Release: the store drops its references and subsequent reads reload
            // through the factories (fresh instances, old ones deallocated).
            await engineStore.releaseEngines()
            #expect(await engineStore.cachedEngineCount == 0)
            #expect(Self.eventuallyNil(weakFirstTextEngine))
            #expect(Self.eventuallyNil(weakFirstVectorEngine))

            _ = try await wax.search(request(), engineStore: engineStore)
            #expect(await textLoads.value == 2)
            #expect(await vectorLoads.value == 2)

            // Pending embeddings were never staged; close is expected to refuse.
            do {
                try await wax.close()
            } catch {
                #expect(Bool(true))
            }
        }
    }

    /// AC-004: closing the owning MemoryOrchestrator releases its engine store.
    @Test func memoryOrchestrator_closeReleasesOwnedEngineStoreEngines() async throws {
        try await TempFiles.withTempFile { url in
            do {
                let seedConfig = TestHelpers.defaultMemoryConfig(vector: false)
                let seed = try await MemoryOrchestrator(at: url, config: seedConfig)
                try await seed.remember("Swift concurrency actors pin nothing forever.")
                try await seed.flush()
                try await seed.close()
            }

            let orchestrator = try await MemoryOrchestrator(at: url, config: TestHelpers.defaultMemoryConfig(vector: false))
            let wax = await orchestrator.wax

            let request = SearchRequest(
                query: "swift concurrency",
                mode: .textOnly,
                topK: 5,
                nowMs: 1_000
            )
            _ = try await wax.search(
                request,
                engineStore: await orchestrator.unifiedEngineStore
            )
            let cachedBeforeClose = await orchestrator.unifiedEngineStore.cachedEngineCount
            #expect(cachedBeforeClose > 0)

            try await orchestrator.close()

            let cachedAfterClose = await orchestrator.unifiedEngineStore.cachedEngineCount
            #expect(cachedAfterClose == 0)
        }
    }

    private static func eventuallyNil(_ object: AnyObject?, timeout: Duration = .seconds(2)) -> Bool {
        if object == nil { return true }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if object == nil { return true }
            usleep(10_000)
        }
        return object == nil
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
