import Foundation
import Testing
import Wax
import WaxCore

@Test
func singleChunkRememberAddsOneFrame() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true

        let content = "canary-7f3a91 single-chunk remember must add one frame"
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count == 1)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let before = await orchestrator.runtimeStats()
        try await orchestrator.remember(content, metadata: ["source": "single-chunk-test"])
        try await orchestrator.flush()
        let after = await orchestrator.runtimeStats()

        let added = after.frameCount - before.frameCount
        #expect(added == 1)
        #expect(after.frameCount == before.frameCount + 1)

        try await orchestrator.remember(content, metadata: ["source": "single-chunk-test"])
        try await orchestrator.flush()
        let afterDuplicate = await orchestrator.runtimeStats()
        #expect(afterDuplicate.frameCount == after.frameCount)

        let hits = try await orchestrator.search(
            query: "canary-7f3a91",
            mode: .textOnly,
            topK: 5
        )
        #expect(!hits.isEmpty)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == 1)
        let meta = try await wax.frameMeta(frameId: 0)
        #expect(meta.role == .document)
        #expect(meta.searchText == content)
        try await wax.close()
    }
}

@Test
func multiChunkRememberKeepsParentAndChunkFrames() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 6, overlapTokens: 0)

        let content = "multi-chunk remember must keep one parent document plus each child chunk frame"
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count >= 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let before = await orchestrator.runtimeStats()
        try await orchestrator.remember(content, metadata: ["source": "multi-chunk-test"])
        try await orchestrator.flush()
        let after = await orchestrator.runtimeStats()

        let expected = UInt64(chunks.count + 1)
        #expect(after.frameCount == before.frameCount + expected)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let doc = try await wax.frameMeta(frameId: 0)
        #expect(doc.role == .document)
        for index in chunks.indices {
            let chunkMeta = try await wax.frameMeta(frameId: UInt64(index + 1))
            #expect(chunkMeta.role == .chunk)
            #expect(chunkMeta.parentId == 0)
            #expect(chunkMeta.chunkIndex == UInt32(index))
            #expect(chunkMeta.chunkCount == UInt32(chunks.count))
        }
        try await wax.close()
    }
}

@Test
func singleChunkRememberRepairsUnsearchableDocument() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true

        let content = "repair-canary-a91c2e incomplete single-chunk must become searchable"
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count == 1)

        let hash = ContentHasher.hash(Data(content.utf8)).hexString
        let metadata = ["source": "incomplete-single-chunk"]
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata([
                    "source": "incomplete-single-chunk",
                    "wax.content.hash": hash,
                ])
            )
        )
        try await wax.commit()
        try await wax.close()

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder()
        )
        let beforeHits = try await orchestrator.search(
            query: "repair-canary-a91c2e",
            mode: .textOnly,
            topK: 5
        )
        #expect(beforeHits.isEmpty)

        let before = await orchestrator.runtimeStats()
        #expect(before.frameCount == 1)

        try await orchestrator.remember(content, metadata: metadata)
        try await orchestrator.flush()
        let after = await orchestrator.runtimeStats()
        #expect(after.frameCount == before.frameCount)

        let textHits = try await orchestrator.search(
            query: "repair-canary-a91c2e",
            mode: .textOnly,
            topK: 5
        )
        #expect(!textHits.isEmpty)

        let vectorHits = try await orchestrator.search(
            query: "repair-canary-a91c2e",
            mode: .vectorOnly,
            topK: 5
        )
        #expect(!vectorHits.isEmpty)

        try await orchestrator.remember(content, metadata: metadata)
        try await orchestrator.flush()
        let afterDuplicate = await orchestrator.runtimeStats()
        #expect(afterDuplicate.frameCount == after.frameCount)

        try await orchestrator.close()
    }
}

@Test
func singleChunkRememberIndexesDocumentForVectorSearch() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true

        let content = "vector canary-7f3a91 single searchable document frame"
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count == 1)

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder()
        )
        try await orchestrator.remember(content, metadata: ["source": "single-chunk-vector"])
        try await orchestrator.flush()

        let after = await orchestrator.runtimeStats()
        #expect(after.frameCount == 1)

        let textHits = try await orchestrator.search(query: "canary-7f3a91", mode: .textOnly, topK: 5)
        #expect(!textHits.isEmpty)

        let vectorHits = try await orchestrator.search(query: "canary-7f3a91", mode: .vectorOnly, topK: 5)
        #expect(!vectorHits.isEmpty)

        try await orchestrator.remember(content, metadata: ["source": "single-chunk-vector"])
        try await orchestrator.flush()
        let afterRematch = await orchestrator.runtimeStats()
        #expect(afterRematch.frameCount == 1)

        try await orchestrator.close()
    }
}

@Test
func singleChunkRememberIsEligibleForSurrogateMaintenance() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true

        let content = "surrogate-canary-b4e18c single-chunk remember must still be a surrogate source"
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count == 1)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content, metadata: ["source": "single-chunk-surrogate"])
        try await orchestrator.flush()

        let report = try await orchestrator.optimizeSurrogates()
        #expect(report.generatedSurrogates == 1)
        #expect(report.eligibleFrames == 1)

        try await orchestrator.close()
    }
}
