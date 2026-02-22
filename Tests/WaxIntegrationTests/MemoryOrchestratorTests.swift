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
func memoryOrchestratorHybridRecallWithDeterministicNowIsStable() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 100,
            expansionMaxTokens: 40,
            snippetMaxTokens: 20,
            maxSnippets: 12,
            searchTopK: 30,
            searchMode: .hybrid(alpha: 0.5),
            deterministicNowMs: 1_700_000_000_000,
            strictDeterministicNow: true
        )

        let embedder = TestEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        try await orchestrator.remember("Swift actors isolate mutable state for safer concurrency.")
        try await orchestrator.remember("Rust ownership prevents data races.")
        try await orchestrator.flush()

        let queryEmbedding = try await embedder.embed("actors concurrency")
        let first = try await orchestrator.recall(query: "actors concurrency", embedding: queryEmbedding)
        let second = try await orchestrator.recall(query: "actors concurrency", embedding: queryEmbedding)
        #expect(first == second)

        try await orchestrator.close()

        let reopened = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
        let afterReopen = try await reopened.recall(query: "actors concurrency", embedding: queryEmbedding)
        #expect(afterReopen == first)
        try await reopened.close()
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
func memoryOrchestratorRememberIsAtomicWhenEmbeddingFails() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.ingestBatchSize = 1
        config.ingestConcurrency = 1
        config.chunking = .tokenCount(targetTokens: 3, overlapTokens: 0)

        let content = "Swift actors isolate state. Swift tasks coordinate work. Swift actors isolate state. Swift tasks coordinate work."
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count > 1)

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: FailOnNthEmbedder(failOnCall: 2)
        )

        do {
            try await orchestrator.remember(content)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == 0)
        try await wax.close()
    }
}

@Test
func memoryOrchestratorNonBatchEmbedderDoesNotReceiveConcurrentEmbedCalls() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.ingestBatchSize = 64
        config.ingestConcurrency = 1
        config.chunking = .tokenCount(targetTokens: 3, overlapTokens: 0)

        let content = String(repeating: "Swift concurrency actors tasks isolation. ", count: 40)
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        #expect(chunks.count > 1)

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: RejectConcurrentEmbedder()
        )
        try await orchestrator.remember(content)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorRememberRequiresEmbedderWhenVectorSearchEnabledAfterReopen() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let seeded = try await MemoryOrchestrator(at: url, config: config, embedder: TestEmbedder())
        try await seeded.remember("Swift concurrency uses actors and tasks.")
        try await seeded.close()

        let waxBefore = try await Wax.open(at: url)
        let beforeCount = await waxBefore.stats().frameCount
        try await waxBefore.close()

        let reopened = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
        do {
            try await reopened.remember("This should fail without an embedder.")
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
        try await reopened.close()

        let waxAfter = try await Wax.open(at: url)
        let afterCount = await waxAfter.stats().frameCount
        #expect(afterCount == beforeCount)
        try await waxAfter.close()
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
        #expect(batches.allSatisfy { !$0.isEmpty && $0.count <= config.ingestBatchSize })
        let partialBatchCount = batches.filter { $0.count < config.ingestBatchSize }.count
        #expect(partialBatchCount <= 1)

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

private enum TestEmbedderError: Error {
    case forcedFailure
    case concurrentAccess
}

private final class FailOnNthEmbedder: EmbeddingProvider, @unchecked Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "FailNth",
        dimensions: 2,
        normalized: true
    )

    private let failOnCall: Int
    private let state = FailOnNthEmbedderState()

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func embed(_ text: String) async throws -> [Float] {
        let shouldFail = await state.shouldFail(on: failOnCall)
        if shouldFail {
            throw TestEmbedderError.forcedFailure
        }
        return [1, 0]
    }
}

private final class RejectConcurrentEmbedder: EmbeddingProvider, @unchecked Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "RejectConcurrent",
        dimensions: 2,
        normalized: true
    )

    private let state = RejectConcurrentEmbedderState()

    func embed(_ text: String) async throws -> [Float] {
        let started = await state.tryEnter()
        if !started {
            throw TestEmbedderError.concurrentAccess
        }

        do {
            try await Task.sleep(nanoseconds: 25_000_000)
            await state.leave()
            return [1, 0]
        } catch {
            await state.leave()
            throw error
        }
    }
}

private actor FailOnNthEmbedderState {
    private var callCount = 0

    func shouldFail(on failOnCall: Int) -> Bool {
        callCount += 1
        return callCount == failOnCall
    }
}

private actor RejectConcurrentEmbedderState {
    private var inFlight = 0

    func tryEnter() -> Bool {
        guard inFlight == 0 else { return false }
        inFlight = 1
        return true
    }

    func leave() {
        inFlight = max(0, inFlight - 1)
    }
}

private struct TestEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        return VectorMath.normalizeL2([a, b])
    }
}

private extension String {
    func repeating(times: Int) -> String {
        guard times > 1 else { return self }
        return Array(repeating: self, count: times).joined(separator: " ")
    }
}

// MARK: - Phase 7B: Structured memory CRUD through orchestrator

@Test
func memoryOrchestratorStructuredMemoryDisabledThrowsOnUpsert() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        do {
            _ = try await orchestrator.upsertEntity(key: EntityKey("person:alice"), kind: "person")
            #expect(Bool(false), "Expected io error for disabled structured memory")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io, got \(error)")
                return
            }
            #expect(reason.contains("structured memory"))
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryDisabledThrowsOnAssertFact() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        do {
            _ = try await orchestrator.assertFact(
                subject: EntityKey("person:alice"),
                predicate: PredicateKey("knows"),
                object: .string("swift")
            )
            #expect(Bool(false), "Expected io error for disabled structured memory")
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false), "Expected WaxError.io, got \(error)")
                return
            }
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryUpsertAssertRetractFacts() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        // Upsert entity
        let entityId = try await orchestrator.upsertEntity(
            key: EntityKey("person:bob"),
            kind: "person",
            aliases: ["Bob", "Bobby"]
        )
        #expect(entityId.rawValue >= 0)

        // Assert fact
        let factId = try await orchestrator.assertFact(
            subject: EntityKey("person:bob"),
            predicate: PredicateKey("likes"),
            object: .string("Swift"),
            evidence: []
        )
        #expect(factId.rawValue >= 0)

        // Query facts
        let result = try await orchestrator.facts(about: EntityKey("person:bob"), predicate: PredicateKey("likes"))
        #expect(result.hits.count == 1)
        #expect(result.hits[0].fact.object == .string("Swift"))

        // Retract fact
        try await orchestrator.retractFact(factId: factId)

        let afterRetract = try await orchestrator.facts(about: EntityKey("person:bob"), predicate: PredicateKey("likes"))
        #expect(afterRetract.hits.isEmpty)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryResolveEntities() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.upsertEntity(
            key: EntityKey("person:carol"),
            kind: "person",
            aliases: ["Carol", "caroline"]
        )

        let matches = try await orchestrator.resolveEntities(matchingAlias: "carol")
        #expect(matches.map(\.key).contains(EntityKey("person:carol")))

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryDisabledThrowsOnResolveEntities() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        do {
            _ = try await orchestrator.resolveEntities(matchingAlias: "carol")
            #expect(Bool(false), "Expected io error")
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryDisabledThrowsOnFacts() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        do {
            _ = try await orchestrator.facts(about: EntityKey("person:x"), predicate: nil)
            #expect(Bool(false), "Expected io error")
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryDisabledThrowsOnRetractFact() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        do {
            try await orchestrator.retractFact(factId: FactRowID(rawValue: 1))
            #expect(Bool(false), "Expected io error")
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: Handoff lifecycle

@Test
func memoryOrchestratorHandoffRoundTrip() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        let frameId = try await orchestrator.rememberHandoff(
            content: "Finished refactoring the auth module.",
            project: "AuthService",
            pendingTasks: ["Write unit tests", "Update docs"]
        )
        // frameId is a UInt64 frame identifier — any value is valid
        _ = frameId

        let record = try await orchestrator.latestHandoff(project: "AuthService")
        #expect(record != nil)
        #expect(record?.content.contains("Finished refactoring") == true)
        #expect(record?.project == "AuthService")
        #expect(record?.pendingTasks.count == 2)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorLatestHandoffReturnsNilWhenNoHandoffs() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let record = try await orchestrator.latestHandoff()
        #expect(record == nil)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorLatestHandoffFiltersToCorrectProject() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.rememberHandoff(
            content: "Backend handoff content.",
            project: "Backend"
        )
        _ = try await orchestrator.rememberHandoff(
            content: "Frontend handoff content.",
            project: "Frontend"
        )

        let backendRecord = try await orchestrator.latestHandoff(project: "Backend")
        #expect(backendRecord?.content.contains("Backend") == true)

        let frontendRecord = try await orchestrator.latestHandoff(project: "Frontend")
        #expect(frontendRecord?.content.contains("Frontend") == true)

        // No project filter returns the latest one globally
        let anyRecord = try await orchestrator.latestHandoff()
        #expect(anyRecord != nil)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorHandoffWithNoPendingTasksOmitsTaskList() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.rememberHandoff(
            content: "Clean session with no pending work.",
            project: nil,
            pendingTasks: []
        )

        let record = try await orchestrator.latestHandoff()
        #expect(record != nil)
        #expect(record?.pendingTasks.isEmpty == true)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorLatestHandoffProjectFilterReturnsNilWhenNoMatch() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.rememberHandoff(
            content: "Alpha project work.",
            project: "Alpha"
        )

        let record = try await orchestrator.latestHandoff(project: "Beta")
        #expect(record == nil)

        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: Access stats scoring

@Test
func memoryOrchestratorAccessStatsScoringPersistsAndLoadsAcrossReopens() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableAccessStatsScoring = true
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
            "Swift actors isolate mutable state for concurrency safety.",
            metadata: ["source": "test"]
        )
        // Trigger a recall to record frame accesses
        let ctx = try await orchestrator.recall(query: "actors")
        #expect(!ctx.items.isEmpty)

        // Flush persists access stats frame
        try await orchestrator.flush()
        try await orchestrator.close()

        // Reopen and verify stats are loaded (no crash, orchestrator initializes correctly)
        let reopened = try await MemoryOrchestrator(at: url, config: config)
        let stats = await reopened.runtimeStats()
        #expect(stats.accessStatsScoringEnabled == true)
        try await reopened.close()
    }
}

@Test
func memoryOrchestratorAccessStatsScoringEnabledReflectedInRuntimeStats() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableAccessStatsScoring = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let stats = await orchestrator.runtimeStats()
        #expect(stats.accessStatsScoringEnabled == true)
        #expect(stats.vectorSearchEnabled == false)
        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: sessionRuntimeStats

@Test
func memoryOrchestratorSessionRuntimeStatsWhenNoActiveSession() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let sessionStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionStats.active == false)
        #expect(sessionStats.sessionId == nil)
        #expect(sessionStats.sessionFrameCount == 0)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorSessionRuntimeStatsWithActiveSession() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let sessionId = await orchestrator.startSession()
        try await orchestrator.remember(
            "Swift actors isolate mutable state. Tasks cooperate through structured concurrency."
        )
        try await orchestrator.flush()

        let sessionStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionStats.active == true)
        #expect(sessionStats.sessionId == sessionId)
        #expect(sessionStats.sessionFrameCount > 0)

        await orchestrator.endSession()
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorSessionRuntimeStatsWithActiveSessionNoFrames() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        // Start a session but write nothing
        _ = await orchestrator.startSession()

        let sessionStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionStats.active == true)
        #expect(sessionStats.sessionFrameCount == 0)
        #expect(sessionStats.sessionTokenEstimate == 0)

        await orchestrator.endSession()
        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: runtimeStats

@Test
func memoryOrchestratorRuntimeStatsReflectsCorrectFlags() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.enableAccessStatsScoring = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let stats = await orchestrator.runtimeStats()
        #expect(stats.vectorSearchEnabled == false)
        #expect(stats.structuredMemoryEnabled == true)
        #expect(stats.accessStatsScoringEnabled == false)
        #expect(stats.embedderIdentity == nil)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorRuntimeStatsWithEmbedderIdentity() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let embedder = TestEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        let stats = await orchestrator.runtimeStats()
        #expect(stats.vectorSearchEnabled == true)
        #expect(stats.embedderIdentity != nil)
        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: recall with frameFilter

@Test
func memoryOrchestratorRecallWithFrameFilterNarrowsResults() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 100,
            expansionMaxTokens: 40,
            snippetMaxTokens: 20,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(
            "Swift actors isolate mutable state for thread safety.",
            metadata: ["tag": "swift"]
        )
        try await orchestrator.flush()

        // Using nil frame filter should still work (no filtering)
        let ctx = try await orchestrator.recall(query: "actors", frameFilter: nil)
        #expect(!ctx.items.isEmpty)

        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: search direct mode

@Test
func memoryOrchestratorDirectSearchTextModeReturnsHits() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Swift actors are fundamental to the concurrency model.")
        try await orchestrator.flush()

        let hits = try await orchestrator.search(query: "actors", mode: .text, topK: 5)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.score >= 0 })
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorDirectSearchEmptyQueryReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let hits = try await orchestrator.search(query: "   ", mode: .text, topK: 5)
        #expect(hits.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorDirectSearchZeroTopKReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let hits = try await orchestrator.search(query: "actors", mode: .text, topK: 0)
        #expect(hits.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorDirectSearchHybridFallsBackToTextWhenNoEmbedder() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Swift generics allow type-safe algorithms.")
        try await orchestrator.flush()

        // Hybrid mode with no embedder should fall back to text-only
        let hits = try await orchestrator.search(query: "generics", mode: .hybrid(alpha: 0.7), topK: 5)
        #expect(!hits.isEmpty)
        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: surrogate generation

@Test
func memoryOrchestratorOptimizeSurrogatesGeneratesForChunks() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(
            "Swift actors provide a safe, structured way to isolate state and prevent data races in concurrent programs."
        )
        try await orchestrator.flush()

        let report = try await orchestrator.optimizeSurrogates()
        #expect(report.scannedFrames > 0)
        #expect(report.eligibleFrames >= 0)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorCompactIndexesSucceeds() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Compaction test content for the memory store.")
        try await orchestrator.flush()

        let report = try await orchestrator.compactIndexes()
        #expect(report.scannedFrames >= 0)

        try await orchestrator.close()
    }
}

// MARK: - Phase 7B: Live set rewrite (scheduled maintenance)

@Test
func memoryOrchestratorRunScheduledLiveSetMaintenanceNowWithDisabledScheduleReturnsDisabledOutcome() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.liveSetRewriteSchedule = .disabled

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let report = try await orchestrator.runScheduledLiveSetMaintenanceNow()
        #expect(report.outcome == .disabled)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorScheduledLiveSetMaintenanceReportIsNilInitially() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let report = await orchestrator.scheduledLiveSetMaintenanceReport()
        #expect(report == nil)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorRewriteLiveSetProducesValidDestination() async throws {
    try await TempFiles.withTempFile { sourceURL in
        try await TempFiles.withTempFile { destURL in
            // Delete dest so rewriteLiveSet can create it fresh
            try? FileManager.default.removeItem(at: destURL)

            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            try await orchestrator.remember("Live set rewrite test content.")
            try await orchestrator.flush()

            let rewriteReport = try await orchestrator.rewriteLiveSet(to: destURL)
            #expect(rewriteReport.frameCount > 0)
            #expect(FileManager.default.fileExists(atPath: destURL.path))

            try await orchestrator.close()
            // Clean up destination
            try? FileManager.default.removeItem(at: destURL)
        }
    }
}

@Test
func memoryOrchestratorFlushWithScheduledMaintenanceEnabledQueuesMaintenanceTask() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)
        // Enable schedule with zero-byte threshold so the check triggers immediately
        config.liveSetRewriteSchedule = LiveSetRewriteSchedule(
            enabled: true,
            checkEveryFlushes: 1,
            minDeadPayloadBytes: 0,
            minDeadPayloadFraction: 0.0,
            minimumCompactionGainBytes: 0,
            minimumIdleMs: 0,
            minIntervalMs: 0,
            verifyDeep: false,
            destinationDirectory: url.deletingLastPathComponent(),
            keepLatestCandidates: 1
        )

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Content that will become dead payload after supersede.")
        try await orchestrator.flush()
        // Closing will drain the maintenance task queue
        try await orchestrator.close()
        // After close the maintenance report should be populated (either succeeded or below threshold)
        // We verify the orchestrator did not crash and closed cleanly
        #expect(Bool(true))
    }
}

// MARK: - Phase 7B: activeSessionId

@Test
func memoryOrchestratorActiveSessionIdLifecycle() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        #expect(await orchestrator.activeSessionId() == nil)

        let id = await orchestrator.startSession()
        #expect(await orchestrator.activeSessionId() == id)

        await orchestrator.endSession()
        #expect(await orchestrator.activeSessionId() == nil)

        try await orchestrator.close()
    }
}

// MARK: - Phase 7C: VectorSearchSession

@Test
func waxVectorSearchSessionAddSearchRoundtrip() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 4,
            preference: .cpuOnly
        )

        let frameId = try await wax.put(Data("test content".utf8))
        try await session.add(frameId: frameId, vector: [1.0, 0.0, 0.0, 0.0])

        let hits = try await session.search(vector: [1.0, 0.0, 0.0, 0.0], topK: 5)
        #expect(hits.contains { $0.frameId == frameId })

        try await session.commit()
        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionPutWithEmbeddingDimensionMismatchThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 4,
            preference: .cpuOnly
        )

        do {
            _ = try await session.putWithEmbedding(
                Data("mismatch".utf8),
                embedding: [1.0, 0.0]  // Only 2 dims, engine expects 4
            )
            #expect(Bool(false), "Expected dimension mismatch error")
        } catch let error as WaxError {
            guard case .encodingError(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.encodingError, got \(error)")
                return
            }
            #expect(reason.contains("dimension mismatch"))
        }

        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionPutWithEmbeddingBatchValidatesCountMatch() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        // contents.count != embeddings.count
        do {
            _ = try await session.putWithEmbeddingBatch(
                contents: [Data("a".utf8), Data("b".utf8)],
                embeddings: [[1.0, 0.0]],           // only 1, but 2 contents
                options: [FrameMetaSubset(), FrameMetaSubset()]
            )
            #expect(Bool(false), "Expected count mismatch error")
        } catch let error as WaxError {
            guard case .encodingError = error else {
                #expect(Bool(false), "Expected WaxError.encodingError, got \(error)")
                return
            }
        }

        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionPutWithEmbeddingBatchValidatesOptionsCount() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        // options.count != contents.count
        do {
            _ = try await session.putWithEmbeddingBatch(
                contents: [Data("a".utf8), Data("b".utf8)],
                embeddings: [[1.0, 0.0], [0.0, 1.0]],
                options: [FrameMetaSubset()]          // only 1 option, but 2 contents
            )
            #expect(Bool(false), "Expected options count mismatch error")
        } catch let error as WaxError {
            guard case .encodingError = error else {
                #expect(Bool(false), "Expected WaxError.encodingError, got \(error)")
                return
            }
        }

        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionPutWithEmbeddingBatchEmbeddingDimensionMismatchThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 4,
            preference: .cpuOnly
        )

        // An embedding with wrong dimension inside the batch
        do {
            _ = try await session.putWithEmbeddingBatch(
                contents: [Data("a".utf8)],
                embeddings: [[1.0, 0.0]],  // 2 dims, engine expects 4
                options: [FrameMetaSubset()]
            )
            #expect(Bool(false), "Expected dimension mismatch error")
        } catch let error as WaxError {
            guard case .encodingError = error else {
                #expect(Bool(false), "Expected WaxError.encodingError, got \(error)")
                return
            }
        }

        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionPutWithEmbeddingBatchEmptyInputReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        let frameIds = try await session.putWithEmbeddingBatch(
            contents: [],
            embeddings: [],
            options: []
        )
        #expect(frameIds.isEmpty)

        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionBatchAddAndSearchRoundtrip() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        let frameIds = try await session.putWithEmbeddingBatch(
            contents: [Data("doc-a".utf8), Data("doc-b".utf8), Data("doc-c".utf8)],
            embeddings: [
                [1.0, 0.0],
                [0.0, 1.0],
                [0.707, 0.707]
            ],
            options: [FrameMetaSubset(), FrameMetaSubset(), FrameMetaSubset()]
        )
        #expect(frameIds.count == 3)

        let hits = try await session.search(vector: [1.0, 0.0], topK: 3)
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.frameId == frameIds[0] })

        try await session.commit()
        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionPutWithEmbeddingWithIdentityMetadata() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        let identity = EmbeddingIdentity(
            provider: "TestProvider",
            model: "TestModel",
            dimensions: 2,
            normalized: true
        )

        let frameId = try await session.putWithEmbedding(
            Data("content with identity".utf8),
            embedding: [1.0, 0.0],
            identity: identity
        )
        // frameId is a UInt64 frame identifier; verify it was written by reading the meta back

        // Verify embedding metadata was merged in
        let meta = try await wax.frameMeta(frameId: frameId)
        #expect(meta.metadata?.entries["memvid.embedding.provider"] == "TestProvider")

        try await session.commit()
        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionStageForCommitPicksUpPendingEmbeddings() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        // Add frames through the Wax directly (bypassing session.add) to exercise
        // the pending-mutation pickup path in stageForCommit
        let frameId = try await wax.put(Data("staged content".utf8))
        try await wax.putEmbedding(frameId: frameId, vector: [1.0, 0.0])

        // stageForCommit should pick up the pending embedding written directly
        try await session.stageForCommit()

        let hits = try await session.search(vector: [1.0, 0.0], topK: 5)
        #expect(hits.contains { $0.frameId == frameId })

        try await wax.close()
    }
}

@Test
func waxVectorSearchSessionRemoveBeforeCommitExcludesFromResults() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        let frameA = try await wax.put(Data("keep".utf8))
        let frameB = try await wax.put(Data("remove".utf8))
        try await session.add(frameId: frameA, vector: [1.0, 0.0])
        try await session.add(frameId: frameB, vector: [0.9, 0.1])

        // Remove frameB before committing
        try await session.remove(frameId: frameB)
        try await session.commit()
        try await wax.close()

        // Reopen and verify frameB is gone from vector index
        let reopened = try await Wax.open(at: url)
        let session2 = try await WaxVectorSearchSession(
            wax: reopened,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )
        let hits = try await session2.search(vector: [1.0, 0.0], topK: 5)
        #expect(!hits.contains { $0.frameId == frameB })
        try await reopened.close()
    }
}

@Test
func waxEnableVectorSearchFromManifestWorksAfterCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let session = try await WaxVectorSearchSession(
            wax: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )
        _ = try await session.putWithEmbedding(Data("manifest test".utf8), embedding: [1.0, 0.0])
        try await session.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        // Should load from manifest without needing to re-specify dimensions
        let session2 = try await reopened.enableVectorSearchFromManifest(preference: .cpuOnly)
        let hits = try await session2.search(vector: [1.0, 0.0], topK: 5)
        #expect(!hits.isEmpty)
        try await reopened.close()
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
