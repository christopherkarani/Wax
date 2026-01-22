import Foundation
import Testing
import Wax

@Test
func memoryOrchestratorRememberFlushRecallReopenAndNoSidecars() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(
            "Swift concurrency uses actors and tasks. Actors isolate mutable state and enable safe parallelism.",
            metadata: ["source": "test"]
        )
        try await orchestrator.flush()

        let ctx1 = try await orchestrator.recall(query: "actors")
        #expect(!ctx1.items.isEmpty)
        #expect(ctx1.items.filter { $0.kind == .expanded }.count <= 1)

        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let related = contents.filter { $0.lastPathComponent.hasPrefix(baseName) }
        #expect(related.count == 1)

        try await orchestrator.close()

        let reopened = try await MemoryOrchestrator(at: url, config: config)
        let ctx2 = try await reopened.recall(query: "actors")
        #expect(!ctx2.items.isEmpty)
        try await reopened.close()
    }
}

@Test
func memoryOrchestratorRecallWithoutFlushFindsRecentText() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(
            "Swift concurrency uses actors and tasks. Actors isolate mutable state.",
            metadata: ["source": "test"]
        )

        let ctx = try await orchestrator.recall(query: "actors")
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.filter { $0.kind == .expanded }.count <= 1)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorSessionTaggingAndChunkMetadataPersist() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let content = "Swift concurrency uses actors and tasks.".repeating(times: 30)
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let session = await orchestrator.startSession()
        try await orchestrator.remember(content, metadata: ["k": "v"])
        await orchestrator.endSession()
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == UInt64(expectedChunks.count + 1))

        let doc = try await wax.frameMeta(frameId: 0)
        #expect(doc.role == .document)
        #expect(doc.metadata?.entries["session_id"] == session.uuidString)
        #expect(doc.metadata?.entries["k"] == "v")

        for (idx, chunk) in expectedChunks.enumerated() {
            let frameId = UInt64(idx + 1)
            let meta = try await wax.frameMeta(frameId: frameId)
            #expect(meta.role == .chunk)
            #expect(meta.parentId == 0)
            #expect(meta.chunkIndex == UInt32(idx))
            #expect(meta.chunkCount == UInt32(expectedChunks.count))
            #expect(meta.searchText == chunk)
            #expect(meta.metadata?.entries["session_id"] == session.uuidString)
            #expect(meta.metadata?.entries["k"] == "v")
        }

        try await wax.close()
    }
}

@Test
func memoryOrchestratorEnableVectorSearchRequiresEmbedder() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true

        do {
            _ = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }
}

@Test
func memoryOrchestratorVectorSearchStagesVecIndexOnFlush() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: TestEmbedder())
        try await orchestrator.remember("Swift concurrency uses actors and tasks.")
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        #expect(await wax.committedVecIndexManifest() != nil)
        try await wax.close()
    }
}

@Test
func memoryOrchestratorVectorRecallWithEmbeddingUsesVectorResults() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .vectorOnly
        )

        let embedder = TestEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        try await orchestrator.remember("Swift concurrency uses actors and tasks.")
        try await orchestrator.flush()

        let embedding = try await embedder.embed("Swift concurrency uses actors and tasks.")
        let ctx = try await orchestrator.recall(query: "irrelevant", embedding: embedding)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.contains { $0.sources.contains(.vector) })

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorReopenVectorSearchWithoutEmbedderAllowsRecallWithEmbedding() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .vectorOnly
        )

        let embedder = TestEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        try await orchestrator.remember("Swift concurrency uses actors and tasks.")
        try await orchestrator.close()

        let reopened = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
        let queryEmbedding = try await embedder.embed("Swift concurrency uses actors and tasks.")
        let ctx = try await reopened.recall(query: "irrelevant", embedding: queryEmbedding)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.contains { $0.sources.contains(.vector) })
        try await reopened.close()
    }
}

@Test
func memoryOrchestratorRecallWithEmbeddingPolicyUsesEmbedderWhenAvailable() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .vectorOnly
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: TestEmbedder())
        try await orchestrator.remember("Swift concurrency uses actors and tasks.")
        try await orchestrator.flush()

        let ctx = try await orchestrator.recall(query: "irrelevant", embeddingPolicy: .ifAvailable)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.contains { $0.sources.contains(.vector) })

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorRespectsIngestBatchingAndOrder() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.ingestBatchSize = 4
        config.ingestConcurrency = 2
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 5, overlapTokens: 0)

        let embedder = RecordingBatchEmbedder(dimensions: 8)

        let text = String(repeating: "Swift concurrency uses actors and tasks. ", count: 80)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        try await orchestrator.remember(text)
        try await orchestrator.flush()
        try await orchestrator.close()

        // Validate batching behavior
        let batches = await embedder.batches
        #expect(!batches.isEmpty)
        #expect(batches.dropLast().allSatisfy { $0.count == config.ingestBatchSize })
        #expect(batches.last?.count ?? 0 > 0)
        #expect(batches.last!.count <= config.ingestBatchSize)

        // Validate chunk ordering persisted
        let reopened = try await Wax.open(at: url)
        let metas = await reopened.frameMetas()
        let chunkMetas = metas.dropFirst()
        let chunkCount = chunkMetas.count

        // Ensure we exercised multi-batch ingest
        #expect(chunkCount >= config.ingestBatchSize * 2)

        let uniqueChunkTexts = Set(chunkMetas.compactMap { $0.searchText })
        let embeddedCount = batches.flatMap { $0 }.count
        #expect(embeddedCount >= uniqueChunkTexts.count)
        #expect(embeddedCount <= chunkCount)

        let indices = chunkMetas.map { $0.chunkIndex }
        let counts = chunkMetas.map { $0.chunkCount }
        #expect(indices == Array(0..<UInt32(chunkCount)))
        #expect(Set(counts) == [UInt32(chunkCount)])
        try await reopened.close()
    }
}

private actor RecordingBatchEmbedder: BatchEmbeddingProvider {
    let dimensions: Int
    let normalize: Bool = false
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "BatchRecorder",
        dimensions: 8,
        normalized: false
    )

    private(set) var batches: [[String]] = []

    init(dimensions: Int) {
        self.dimensions = dimensions
    }

    func embed(_ text: String) async throws -> [Float] {
        try await embed(batch: [text]).first ?? []
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        batches.append(texts)
        return texts.enumerated().map { index, _ in
            let base = Float(index + 1)
            return [base, base, base, base, base, base, base, base]
        }
    }
}

private struct TestEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = false
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Deterministic",
        dimensions: 2,
        normalized: false
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        return [a, b]
    }
}

private extension String {
    func repeating(times: Int) -> String {
        guard times > 1 else { return self }
        return Array(repeating: self, count: times).joined(separator: " ")
    }
}

#if canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM

@Test
func miniLMAdapterSymbolsExistWhenAvailable() async {
    _ = MiniLMEmbedder.self
    _ = MemoryOrchestrator.openMiniLM
    #expect(Bool(true))
}
#endif
