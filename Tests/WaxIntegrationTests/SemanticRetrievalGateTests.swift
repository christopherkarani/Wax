import Foundation
import Testing
import Wax

// Ungated semantic-retrieval gate. Unlike the stub-embedder suites, these tests load
// the real built-in MiniLM model and assert paraphrase retrieval through the public
// Memory facade — the query shares no content tokens with the stored text, so a
// text-only pipeline cannot rank the target first. If semantic search silently
// degrades (no embedder, vector lane dropped), these tests fail loudly.

private let semanticGateTarget = "The user's favorite beverage is oolong tea."
private let semanticGateDistractors = [
    "Swift 6.2 introduces improved concurrency.",
    "Async/await makes code more readable.",
    "The capital of France is Paris.",
]

@Test
func memoryDefaultInitAutoWiresBuiltInEmbedderAndRetrievesParaphrase() async throws {
    try await TempFiles.withTempFile { url in
        // Default config: enableVectorSearch == true, no explicit embedder.
        // On iOS 18/macOS 15+ with the default MiniLMEmbeddings trait this must
        // auto-wire the built-in MiniLM embedder.
        let memory = try await Memory(at: url)
        try await waitUntilEmbeddingReady(memory)

        let stats = await memory.stats()
        #expect(
            stats.queryEmbedderConfigured,
            "default Memory(at:) did not configure a query embedder; semantic search would silently degrade"
        )
        #expect(stats.vectorSearchEnabled)

        try await memory.save(semanticGateTarget)
        for distractor in semanticGateDistractors {
            try await memory.save(distractor)
        }
        try await memory.flush()

        // Paraphrase query: shares no content tokens with the target sentence.
        let results = try await memory.search(
            "What does the person like to drink?",
            options: .init(topK: 1, mode: .vectorOnly)
        )

        #expect(results.items.first?.text.contains("oolong tea") == true)
        #expect(results.items.first?.sources.contains(.vector) == true)

        let diagnostics = try #require(results.diagnostics)
        #expect(diagnostics.effectiveMode == "vector")
        #expect(diagnostics.queryEmbeddingState == .available)

        try await memory.close()
    }
}

@Test
func memoryBuiltInMiniLMHybridSearchRunsVectorLaneForParaphrase() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { $0.embedding = .builtIn(.miniLM) }

        try await memory.save(semanticGateTarget)
        for distractor in semanticGateDistractors {
            try await memory.save(distractor)
        }
        try await memory.flush()

        let results = try await memory.search(
            "Which drink does the person prefer?",
            options: .init(topK: 3, mode: .hybrid())
        )

        let top = try #require(results.items.first)
        #expect(top.text.contains("oolong tea"))
        #expect(
            top.sources.contains(.vector),
            "hybrid search returned the paraphrase hit without the vector lane; semantic retrieval is degraded"
        )

        let diagnostics = try #require(results.diagnostics)
        #expect(diagnostics.requestedMode.contains("hybrid"))
        #expect(diagnostics.effectiveMode.contains("hybrid"))
        #expect(diagnostics.queryEmbeddingState == .available)

        try await memory.close()
    }
}

private func waitUntilEmbeddingReady(_ memory: Memory, timeout: Duration = .seconds(180)) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        switch await memory.stats().embeddingStatus {
        case .active, .degraded:
            return
        case .unavailable(let reason):
            Issue.record("default Memory(at:) embedder unavailable: \(reason)")
            throw WaxError.io("embedding provider unavailable: \(reason)")
        case .disabled, .loading:
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    throw WaxError.io("timed out waiting for automatic embedding readiness")
}
