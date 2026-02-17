import Foundation
import Testing
import Wax

@Test
func memoryOrchestratorConcurrentIngestAndRecallNoRace() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await makeConcurrentStressOrchestrator(at: url)
        try await orchestrator.remember("Initial memory about Swift concurrency and actors.")
        try await orchestrator.flush()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    try await orchestrator.remember("Concurrent memory \(index) topic \(index % 3)")
                }
            }

            for _ in 0..<5 {
                group.addTask {
                    _ = try await orchestrator.recall(query: "Swift concurrency")
                }
            }

            try await group.waitForAll()
        }

        try await orchestrator.flush()
        let finalContext = try await orchestrator.recall(query: "Concurrent memory")
        #expect(!finalContext.items.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorRapidIngestRecallCyclesDoNotCrash() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await makeConcurrentStressOrchestrator(at: url)

        for index in 0..<20 {
            try await orchestrator.remember("Memory \(index) about actor isolation")
            _ = try await orchestrator.recall(query: "Memory \(index)")
        }

        try await orchestrator.close()
    }
}

private func makeConcurrentStressOrchestrator(at url: URL) async throws -> MemoryOrchestrator {
    var config = TestHelpers.defaultMemoryConfig(vector: true)
    config.rag = FastRAGConfig(
        maxContextTokens: 128,
        expansionMaxTokens: 48,
        snippetMaxTokens: 20,
        maxSnippets: 8,
        searchTopK: 24,
        searchMode: .hybrid(alpha: 0.5)
    )
    return try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: DeterministicTextEmbedder()
    )
}
