import Foundation
import Testing
@testable import Wax

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

@Test
func unifiedSearchVectorTimeoutFallsBackToTextLane() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let id0 = try await wax.put(Data("Swift programming language".utf8))
        try await text.index(frameId: id0, text: "Swift programming language")
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
            var ingestConfig = TestHelpers.defaultMemoryConfig(vector: false)
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
