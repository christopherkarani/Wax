import Foundation
import Testing
@testable import Wax

@Test
func enrichmentPipelineProcessesEnqueuedTasks() async throws {
    let pipeline = EnrichmentPipeline()
    await pipeline.start { task in
        EnrichmentResult(
            frameId: task.frameId,
            keywords: KeywordExtractor.extract(from: task.text),
            entities: []
        )
    }

    try await pipeline.enqueue(EnrichmentTask(frameId: 1, text: "Swift concurrency is great"))
    try await pipeline.enqueue(EnrichmentTask(frameId: 2, text: "Rust ownership model"))

    try await pipeline.waitUntilProcessed(atLeast: 2, timeout: .seconds(2))
    let stats = await pipeline.stats
    #expect(stats.processedCount >= 2)
    #expect(stats.pendingCount == 0)
    try await pipeline.stop()
}

@Test
func memoryOrchestratorCloseDrainsEnrichmentQueue() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableAsyncEnrichment = true
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(String(repeating: "Swift concurrency actors tasks. ", count: 40))

        let beforeClose = await orchestrator.enrichmentStatsForTesting()?.processedCount ?? 0
        try await orchestrator.close()
        let afterClose = await orchestrator.enrichmentStatsForTesting()?.processedCount ?? 0

        #expect(afterClose >= beforeClose)
        #expect(afterClose > 0)
    }
}
