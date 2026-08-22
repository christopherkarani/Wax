import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch
import WaxVectorSearch

private actor HangingVectorEngine: VectorSearchEngine {
    let dimensions: Int

    init(dimensions: Int) {
        self.dimensions = dimensions
    }

    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        _ = vector
        _ = topK
        // Sleep "forever" (cancellable) to simulate a hung engine without triggering
        // Swift's checked-continuation misuse diagnostics in tests.
        try await Task.sleep(for: .seconds(60))
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

/// Injectable orchestrator clock so breaker tests advance time without sleeping.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) {
        value = start
    }

    var nowMs: Int64 {
        get { lock.withLock { value } }
    }

    func advance(ms: Int64) {
        lock.withLock { value += ms }
    }
}

@Suite
struct TimeoutFallbackTests {
    @Test
    func unifiedSearchVectorTimeoutFallsBackToTextLane() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))

            let id0 = try await wax.put(Data("Swift programming language".utf8))
            try await text.indexText(frameId: id0, text: "Swift programming language")
            try await text.commit()

            let overrides = UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: HangingVectorEngine(dimensions: 2),
                structuredEngine: nil
            )

            let request = SearchRequest(
                query: "Swift",
                embedding: [1.0, 0.0],
                vectorSearchTimeout: .milliseconds(25),
                mode: .hybrid(alpha: 0.5),
                topK: 10
            )

            let response = try await wax.search(request, engineOverrides: overrides)

            #expect(response.results.first?.frameId == id0)
            #expect(response.results.first?.sources.contains(.text) == true)

            try await wax.close()
        }
    }

    @Test
    func unifiedSearchVectorTimeoutThrowsForVectorOnly() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)

            let overrides = UnifiedSearchEngineOverrides(
                textEngine: nil,
                vectorEngine: HangingVectorEngine(dimensions: 2),
                structuredEngine: nil
            )

            let request = SearchRequest(
                embedding: [1.0, 0.0],
                vectorSearchTimeout: .milliseconds(25),
                mode: .vectorOnly,
                topK: 10
            )

            do {
                _ = try await wax.search(request, engineOverrides: overrides)
                #expect(Bool(false))
            } catch {
                #expect(Bool(true))
            }

            try await wax.close()
        }
    }

    @Test
    func memoryOrchestratorQueryEmbeddingTimeoutFallsBackAndOpensCircuit() async throws {
        try await TempFiles.withTempFile { url in
            // Seed a store with text-only ingest to avoid calling the hanging embedder during `remember`.
            do {
                let ingestConfig = TestHelpers.defaultMemoryConfig(vector: false)
                let ingest = try await MemoryOrchestrator(at: url, config: ingestConfig)
                try await ingest.remember("Swift concurrency actors and tasks.")
                try await ingest.flush()
                try await ingest.close()
            }

            let embedder = HangingCountingEmbedder()

            var config = TestHelpers.defaultMemoryConfig(vector: true)
            config.queryEmbeddingTimeout = .milliseconds(25)

            let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)

            let hits1 = try await orchestrator.search(
                query: "Swift concurrency",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil
            )
            #expect(!hits1.isEmpty)
            #expect(await embedder.callCount() == 1)

            // Second call should not attempt embedding again (circuit breaker).
            let hits2 = try await orchestrator.search(
                query: "Swift concurrency",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil
            )
            #expect(!hits2.isEmpty)
            #expect(await embedder.callCount() == 1)

            try await orchestrator.close()
        }
    }

    @Test
    func memoryOrchestratorQueryEmbeddingCircuitHalfOpensAfterCooldown() async throws {
        try await TempFiles.withTempFile { url in
            // Seed a store with text-only ingest to avoid calling the hanging embedder during `remember`.
            do {
                let ingestConfig = TestHelpers.defaultMemoryConfig(vector: false)
                let ingest = try await MemoryOrchestrator(at: url, config: ingestConfig)
                try await ingest.remember("Swift concurrency actors and tasks.")
                try await ingest.flush()
                try await ingest.close()
            }

            let embedder = HangingCountingEmbedder()
            let clock = MutableClock(1_700_000_000_000)

            // The injected clock freezes time between searches, so even a wide cooldown
            // keeps the immediate follow-up deterministic under `swift test --parallel`.
            var config = TestHelpers.defaultMemoryConfig(vector: true)
            config.queryEmbeddingTimeout = .milliseconds(25)
            config.queryEmbeddingCircuitCooldown = .seconds(60)

            let orchestrator = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: embedder,
                nowMsProvider: { clock.nowMs }
            )

            // First query times out and trips the circuit.
            let exec1 = try await orchestrator.searchExecution(
                query: "Swift concurrency",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
            #expect(exec1.queryEmbeddingState == .timeout)
            #expect(await embedder.callCount() == 1)

            // Within the cooldown window the circuit stays open: no new embed attempt.
            let exec2 = try await orchestrator.searchExecution(
                query: "Swift concurrency",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
            #expect(exec2.queryEmbeddingState == .circuitOpen)
            #expect(await embedder.callCount() == 1)

            // After the cooldown elapses the breaker half-opens and retries instead of
            // latching permanently. (The hanging embedder times out again, re-opening it.)
            clock.advance(ms: 60_000)
            let exec3 = try await orchestrator.searchExecution(
                query: "Swift concurrency",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
            #expect(exec3.queryEmbeddingState == .timeout)
            #expect(await embedder.callCount() == 2)

            // Exactly at the boundary elapsed >= cooldown closes the circuit again
            // (half-open probe runs; it times out once more).
            clock.advance(ms: 60_000)
            let exec4 = try await orchestrator.searchExecution(
                query: "Swift concurrency",
                mode: .hybrid(alpha: 0.5),
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
            #expect(exec4.queryEmbeddingState == .timeout)
            #expect(await embedder.callCount() == 3)

            try await orchestrator.close()
        }
    }
}
