import Foundation
import Testing
import Wax
import WaxCore
import WaxVectorSearch

/// One-hot keyword vectors. `rotation` moves every keyword to another axis, so two
/// rotations model two vector spaces that are unrelated to each other.
private struct KeywordEmbedder: EmbeddingProvider, Sendable {
    static let keywords = ["apple", "banana", "cherry", "durian"]

    let dimensions: Int
    let normalize = true
    let identity: EmbeddingIdentity?
    let rotation: Int
    let failAfterCalls: Int?
    let calls: CallCounter?

    init(model: String, rotation: Int, dimensions: Int = 4, failAfterCalls: Int? = nil) {
        self.dimensions = dimensions
        self.identity = EmbeddingIdentity(provider: "Wax", model: model, dimensions: dimensions, normalized: true)
        self.rotation = rotation
        self.failAfterCalls = failAfterCalls
        self.calls = failAfterCalls == nil ? nil : CallCounter()
    }

    func embed(_ text: String) async throws -> [Float] {
        if let failAfterCalls, let calls, await calls.next() > failAfterCalls {
            throw WaxError.io("simulated embedder crash")
        }
        let lowered = text.lowercased()
        let axis = Self.keywords.firstIndex { lowered.contains($0) } ?? 3
        var vector = [Float](repeating: 0, count: dimensions)
        vector[(axis + rotation) % dimensions] = 1
        return vector
    }
}

private actor CallCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private enum Fixture {
    static let documents = [
        "apple pie recipe from grandma",
        "banana bread baking notes",
        "cherry tart planning list",
    ]

    static func config() -> OrchestratorConfig {
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: 32, overlapTokens: 0)
        config.ingestBatchSize = 1
        return config
    }

    /// A store written by the pre-#257 MiniLM identity, in vector space `rotation: 0`.
    static func writeLegacyStore(at url: URL) async throws {
        let legacy = KeywordEmbedder(model: "MiniLMAll", rotation: 0)
        let writer = try await MemoryOrchestrator(at: url, config: config(), embedder: legacy)
        for document in documents {
            try await writer.remember(document)
        }
        try await writer.flush()
        try await writer.close()
    }

    static func current(failAfterCalls: Int? = nil) -> KeywordEmbedder {
        KeywordEmbedder(model: "MiniLMAll-mean", rotation: 2, failAfterCalls: failAfterCalls)
    }

    static func boundModel(at url: URL) async throws -> String? {
        let wax = try await Wax.open(at: url)
        let model = await wax.memoryBinding()?.embeddingModel
        try await wax.close()
        return model
    }
}

@Test func supersededMiniLMStoreServesTextOnlyUntilReembedSwapsBinding() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        let before = await memory.runtimeStats()
        #expect(before.vectorsNeedReembed)
        #expect(before.embeddingStatus == .degraded(Fixture.current().identity, reason: "vectors from superseded MiniLM revision"))

        // Stale vectors are excluded: hybrid degrades to text, vector-only refuses.
        let hybrid = try await memory.searchExecution(query: "apple", mode: .hybrid(), topK: 3)
        #expect(hybrid.queryEmbeddingState == .vectorsRebuilding)
        #expect(hybrid.effectiveMode == .textOnly)
        #expect(hybrid.hits.first?.previewText?.contains("apple") == true)
        await #expect(throws: WaxError.self) {
            _ = try await memory.searchExecution(query: "apple", mode: .vectorOnly, topK: 1)
        }

        // The searches above already scheduled the automatic re-embed; the explicit call
        // serializes behind it (or does the work itself) and returns once it is done.
        _ = try await memory.backfillUnembedded()
        let after = await memory.runtimeStats()
        #expect(!after.vectorsNeedReembed)
        #expect(after.embeddingStatus == .active(Fixture.current().identity))

        // Every stale vector was overwritten: each keyword finds its own document.
        for keyword in ["apple", "banana", "cherry"] {
            let vector = try await memory.searchExecution(query: keyword, mode: .vectorOnly, topK: 1)
            #expect(vector.queryEmbeddingState == .available)
            #expect(vector.hits.first?.previewText?.contains(keyword) == true, "vector hit for \(keyword)")
        }
        try await memory.close()

        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
        let reopened = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        #expect(!(await reopened.runtimeStats().vectorsNeedReembed))
        try await reopened.close()
    }
}

@Test func supersededMiniLMStoreReembedsAutomatically() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        // The first search that meets the stale lane schedules the re-embed.
        _ = try await memory.searchExecution(query: "banana", mode: .hybrid(), topK: 1)
        var polls = 0
        while await memory.runtimeStats().vectorsNeedReembed, polls < 500 {
            polls += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!(await memory.runtimeStats().vectorsNeedReembed))
        let vector = try await memory.searchExecution(query: "banana", mode: .vectorOnly, topK: 1)
        #expect(vector.hits.first?.previewText?.contains("banana") == true)
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func interruptedReembedKeepsOldBindingAndRestartsOnReopen() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        // The embedder dies after the first re-embedded frame; partial vectors are flushed.
        let crashing = try await MemoryOrchestrator(
            at: url,
            config: Fixture.config(),
            embedder: Fixture.current(failAfterCalls: 1)
        )
        await #expect(throws: WaxError.self) {
            _ = try await crashing.backfillUnembedded()
        }
        try await crashing.flush()
        try await crashing.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")

        let restarted = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        #expect(await restarted.runtimeStats().vectorsNeedReembed)
        let reembedded = try await restarted.backfillUnembedded()
        #expect(reembedded >= UInt64(Fixture.documents.count))
        for keyword in ["apple", "banana", "cherry"] {
            let vector = try await restarted.searchExecution(query: keyword, mode: .vectorOnly, topK: 1)
            #expect(vector.hits.first?.previewText?.contains(keyword) == true, "vector hit for \(keyword)")
        }
        try await restarted.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func unboundStoreWithVectorsIsTreatedAsSupersededMiniLM() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)
        let wax = try await Wax.open(at: url)
        try await wax.overwriteMemoryBindingForTesting(nil)
        try await wax.commit()
        try await wax.close()

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        #expect(await memory.runtimeStats().vectorsNeedReembed)
        _ = try await memory.backfillUnembedded()
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func differentModelOrShapeStillFailsInsteadOfReembedding() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        await #expect(throws: WaxError.self) {
            _ = try await MemoryOrchestrator(
                at: url,
                config: Fixture.config(),
                embedder: KeywordEmbedder(model: "OtherModel", rotation: 0)
            )
        }
        await #expect(throws: WaxError.self) {
            _ = try await MemoryOrchestrator(
                at: url,
                config: Fixture.config(),
                embedder: KeywordEmbedder(model: "MiniLMAll-mean", rotation: 0, dimensions: 8)
            )
        }
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")
    }
}
