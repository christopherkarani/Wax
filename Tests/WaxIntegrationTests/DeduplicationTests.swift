import Foundation
import Testing
import Wax

@Test func rememberIdenticalContentTwiceIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Duplicate content test")
        try await orchestrator.flush()

        let afterFirst = await orchestrator.runtimeStats().frameCount

        try await orchestrator.remember("Duplicate content test")
        try await orchestrator.flush()
        let afterSecond = await orchestrator.runtimeStats().frameCount

        #expect(afterSecond == afterFirst)
        try await orchestrator.close()
    }
}

@Test func rememberDifferentContentIncreasesFrameCount() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("First content")
        try await orchestrator.flush()
        let afterFirst = await orchestrator.runtimeStats().frameCount

        try await orchestrator.remember("Second content")
        try await orchestrator.flush()
        let afterSecond = await orchestrator.runtimeStats().frameCount

        #expect(afterSecond > afterFirst)
        try await orchestrator.close()
    }
}

@Test func rememberRetryAfterPartialFailureRepairsMissingChunks() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.ingestBatchSize = 1
        config.chunking = .tokenCount(targetTokens: 3, overlapTokens: 0)

        let content = "retry repair path for partial ingest failure should recover on subsequent remember"

        let failing = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: WrongDimensionTextEmbedder()
        )
        do {
            try await failing.remember(content)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
        try await failing.close()

        let retry = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder()
        )
        try await retry.remember(content)
        try await retry.flush()

        let stats = await retry.runtimeStats()
        #expect(stats.frameCount > 1)

        let recall = try await retry.recall(query: "partial ingest failure recover")
        #expect(!recall.items.isEmpty)
        try await retry.close()
    }
}
