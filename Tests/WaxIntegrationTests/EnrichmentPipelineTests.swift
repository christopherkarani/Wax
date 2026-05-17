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
func enrichmentPipelineWaitUntilIdleWithoutTimeoutDrainsSlowTask() async throws {
    let pipeline = EnrichmentPipeline()
    await pipeline.start { task in
        try? await Task.sleep(for: .seconds(3))
        return EnrichmentResult(frameId: task.frameId, keywords: [], entities: [])
    }

    try await pipeline.enqueue(EnrichmentTask(frameId: 42, text: "slow task"))
    try await pipeline.waitUntilIdle()
    let stats = await pipeline.stats
    #expect(stats.pendingCount == 0)
    #expect(stats.processedCount >= 1)
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

@Test
func memoryOrchestratorPersistsEnrichmentResults() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false
        config.enableAsyncEnrichment = true
        config.chunking = .tokenCount(targetTokens: 64, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Swift concurrency enrichment stores durable keywords.")
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let metas = await wax.frameMetas()
        try await wax.close()

        let enrichment = try #require(metas.first { meta in
            meta.kind == "enrichment" && meta.role == .system
        })
        #expect(enrichment.parentId != nil)
        let metadata = enrichment.metadata?.entries ?? [:]
        #expect(metadata["wax.enrichment.keywords"]?.contains("concurrency") == true)
    }
}

@Test
func memoryOrchestratorPersistsEnrichmentEntities() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false
        config.enableAsyncEnrichment = true
        config.chunking = .tokenCount(targetTokens: 64, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Atlas-10 launch review assigned to Ada Lovelace.")
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let metas = await wax.frameMetas()
        try await wax.close()

        let enrichment = try #require(metas.first { meta in
            meta.kind == "enrichment" && meta.role == .system
        })
        let metadata = enrichment.metadata?.entries ?? [:]
        #expect(metadata["wax.enrichment.entities"]?.contains("Atlas-10|mentioned_in|source_text") == true)
        #expect(metadata["wax.enrichment.entities"]?.contains("Ada Lovelace|mentioned_in|source_text") == true)
    }
}

@Test
func memoryOrchestratorCloseHandlesLongEnrichmentWorkload() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false
        config.enableAsyncEnrichment = true
        config.chunking = .tokenCount(targetTokens: 500_000, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let content = (0..<350_000).map { "enrich\($0)" }.joined(separator: " ")
        try await orchestrator.remember(content)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorFlushDoesNotFailOnEnrichmentDrainTimeout() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false
        config.enableAsyncEnrichment = true
        config.enrichmentFlushDrainTimeout = .milliseconds(1)
        config.enrichmentStopTimeout = .milliseconds(1)
        config.chunking = .tokenCount(targetTokens: 500_000, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let content = (0..<350_000).map { "flush\($0)" }.joined(separator: " ")
        try await orchestrator.remember(content)

        try await orchestrator.flush()
        try await orchestrator.close()
    }
}
