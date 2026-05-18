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

@Test func rememberIdenticalContentTwiceBeforeFlushIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false

        let content = "Pending duplicate content test"
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let stats = await orchestrator.runtimeStats()
        #expect(stats.frameCount == UInt64(expectedChunks.count + 1))

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

@Test func rememberIdenticalContentAcrossSessionsPersistsEachScope() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let content = "Scoped duplicate content must persist independently per session."

        let sessionA = await orchestrator.startSession()
        try await orchestrator.remember(content)
        try await orchestrator.flush()
        let sessionAStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionAStats.active)
        #expect(sessionAStats.sessionId == sessionA)
        #expect(sessionAStats.sessionFrameCount > 0)

        let sessionB = await orchestrator.startSession()
        try await orchestrator.remember(content)
        try await orchestrator.flush()
        let sessionBStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionBStats.active)
        #expect(sessionBStats.sessionId == sessionB)
        #expect(sessionBStats.sessionFrameCount > 0)
        #expect(sessionBStats.sessionFrameCount == sessionAStats.sessionFrameCount)

        let runtime = await orchestrator.runtimeStats()
        #expect(runtime.frameCount >= UInt64(sessionAStats.sessionFrameCount + sessionBStats.sessionFrameCount))
        try await orchestrator.close()
    }
}

@Test func rememberDedupProbeFindsCompleteScopedDocument() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 6, overlapTokens: 0)

        let content = "Scoped duplicate content must remain complete to short-circuit remember."
        let hash = ContentHasher.hash(Data(content.utf8)).hexString
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content, metadata: ["scope": "alpha"])
        try await orchestrator.flush()
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let probe = await wax.rememberDedupProbe(
            contentHash: hash,
            metadata: [
                "scope": "alpha",
                "wax.content.hash": hash,
            ],
            expectedChunkCount: chunks.count,
            embeddingIdentity: nil
        )

        #expect(probe != nil)
        #expect(probe?.isComplete == true)
        try await wax.close()
    }
}

@Test func rememberDedupProbeKeepsPartialScopedDocumentRetryable() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let docHash = ContentHasher.hash(Data("partial".utf8)).hexString

        let docId = try await wax.put(
            Data("partial".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata([
                    "scope": "beta",
                    "wax.content.hash": docHash,
                ])
            )
        )
        _ = try await wax.put(
            Data("chunk 0".utf8),
            options: FrameMetaSubset(
                role: .chunk,
                parentId: docId,
                chunkIndex: 0,
                chunkCount: 2,
                metadata: Metadata(["scope": "beta"])
            )
        )
        try await wax.commit()

        let probe = await wax.rememberDedupProbe(
            contentHash: docHash,
            metadata: [
                "scope": "beta",
                "wax.content.hash": docHash,
            ],
            expectedChunkCount: 2,
            embeddingIdentity: nil
        )

        #expect(probe != nil)
        #expect(probe?.isComplete == false)
        try await wax.close()
    }
}
