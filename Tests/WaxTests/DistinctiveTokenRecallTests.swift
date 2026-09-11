import Foundation
import Testing
@testable import Wax

private struct JobRecallEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "JobRecallTests",
        model: "Deterministic",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let lower = text.lowercased()
        if lower.contains("why agents use text")
            || lower.contains("reciprocal rank")
            || lower.contains("minilm") {
            return [1, 0, 0, 0]
        }
        if lower.contains("hard-codes recall mode") {
            return [0, 1, 0, 0]
        }
        return [0, 0, 1, 0]
    }
}

private func withJobRecallMemory<T>(
    nowMs: Int64,
    _ body: (MemoryOrchestrator) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-job-recall-" + UUID().uuidString)
        .appendingPathExtension("wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = true
    config.enableStructuredMemory = false
    config.rag.searchMode = .hybrid(alpha: 0.5)
    config.rag.deterministicNowMs = nowMs

    let memory = try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: JobRecallEmbedder()
    )
    do {
        let result = try await body(memory)
        try await memory.close()
        try? FileManager.default.removeItem(at: url)
        return result
    } catch {
        try? await memory.close()
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

@Test
func hybridJobRecallRanksRecentLexicalFactAboveOldVectorLesson() async throws {
    let nowMs: Int64 = 1_700_000_000_000
    let dayMs: Int64 = 24 * 60 * 60 * 1000
    let query = "why agents use text search instead of vector semantic search waxmcp recall mode default"

    try await withJobRecallMemory(nowMs: nowMs) { memory in
        try await memory.remember(
            "MiniLM reciprocal rank fusion blends embedding neighbors for session memory.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - 14 * dayMs),
            ]
        )
        try await memory.remember(
            "Agents use text search because the waxmcp playbook hard-codes recall mode text; hybrid ranks old vector lessons first.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.fact.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                MemoryMetadataKeys.createdAtMs: String(nowMs - dayMs),
            ]
        )
        try await memory.flush()

        #expect(RuleBasedQueryClassifier.classify(query) == .exploratory)

        let hits = try await memory.search(query: query, mode: .hybrid(), topK: 5)
        let topHit = try #require(hits.first)
        #expect(
            topHit.previewText?.contains("hard-codes recall mode") == true,
            "hybrid search rank-1 was \(topHit.previewText ?? "<nil>")"
        )
        #expect(topHit.sources.contains(.text))

        let omitted = try await memory.recallExecution(query: query, topK: 5)
        #expect(omitted.requestedMode == .hybrid(alpha: 0.5))
        #expect(omitted.effectiveMode == .hybrid(alpha: 0.5))
        let topRecall = try #require(omitted.context.items.first)
        #expect(
            topRecall.text.contains("hard-codes recall mode"),
            "hybrid recall rank-1 was \(topRecall.text)"
        )
    }
}
