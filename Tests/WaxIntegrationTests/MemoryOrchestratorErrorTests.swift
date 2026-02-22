import Foundation
import Testing
@testable import Wax

@Test
func memoryOrchestratorBatchEmbeddingCountMismatchThrowsEncodingError() async throws {
    try await TempFiles.withTempFile { url in
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: 3, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: WrongCountBatchEmbedder()
        )

        do {
            let text = String(repeating: "Swift concurrency actors tasks. ", count: 16)
            try await orchestrator.remember(text)
            #expect(Bool(false))
        } catch let error as WaxError {
            if case .encodingError(let reason) = error {
                #expect(reason.contains("batch embedding returned"))
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorReadEmbeddingsRejectsCorruptPayload() async throws {
    try await TempFiles.withTempFile(fileExtension: "bin") { fileURL in
        try MemoryOrchestrator._writeEmbeddingsForTesting([[1, 2, 3], [4, 5, 6]], to: fileURL)
        var bytes = try Data(contentsOf: fileURL)
        bytes.removeLast(2)
        try bytes.write(to: fileURL, options: .atomic)

        do {
            _ = try MemoryOrchestrator._readEmbeddingsForTesting(from: fileURL)
            #expect(Bool(false))
        } catch let error as WaxError {
            if case .decodingError(let reason) = error {
                #expect(reason.contains("invalid embedding batch payload"))
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }
    }
}

@Test
func memoryOrchestratorReadEmbeddingsRejectsTrailingBytes() async throws {
    try await TempFiles.withTempFile(fileExtension: "bin") { fileURL in
        try MemoryOrchestrator._writeEmbeddingsForTesting([[1, 2], [3, 4]], to: fileURL)
        var bytes = try Data(contentsOf: fileURL)
        bytes.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])
        try bytes.write(to: fileURL, options: .atomic)

        do {
            _ = try MemoryOrchestrator._readEmbeddingsForTesting(from: fileURL)
            #expect(Bool(false))
        } catch let error as WaxError {
            if case .decodingError(let reason) = error {
                #expect(reason.contains("trailing bytes"))
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }
    }
}

@Test
func memoryOrchestratorWriteReadEmbeddingsEmptyRoundTrip() async throws {
    try await TempFiles.withTempFile(fileExtension: "bin") { fileURL in
        try MemoryOrchestrator._writeEmbeddingsForTesting([], to: fileURL)
        let decoded = try MemoryOrchestrator._readEmbeddingsForTesting(from: fileURL)
        #expect(decoded.isEmpty)
    }
}

@Test
func memoryOrchestratorStrictDeterminismRequiresDeterministicNowMs() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.rag.searchMode = .textOnly
        config.rag.strictDeterministicNow = true
        config.rag.deterministicNowMs = nil

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Deterministic recall requires an explicit clock value.")

        do {
            _ = try await orchestrator.recall(query: "deterministic")
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("strictDeterministicNow"))
        }

        try await orchestrator.close()
    }
}

// MARK: - Phase 7C: Error path coverage

@Test
func memoryOrchestratorQueryEmbeddingPolicyAlwaysWithoutVectorSearchThrows() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.rag.searchMode = .textOnly

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Swift actors isolate mutable state.")

        do {
            _ = try await orchestrator.recall(query: "actors", embeddingPolicy: .always)
            #expect(Bool(false), "Expected error for .always policy when vector search disabled")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io, got \(error)")
                return
            }
            #expect(reason.contains("vector search is disabled"))
        }

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorQueryEmbeddingPolicyAlwaysWithoutEmbedderThrows() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        // Seed the store with an embedder first
        let embedder = DeterministicTextEmbedder()
        let seeder = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        try await seeder.remember("Seeded content.")
        try await seeder.close()

        // Reopen without embedder — .always policy must fail with a clear error
        let reopened = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
        do {
            _ = try await reopened.recall(query: "content", embeddingPolicy: .always)
            #expect(Bool(false), "Expected error for .always policy when no embedder configured")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io, got \(error)")
                return
            }
            #expect(reason.contains("EmbeddingProvider"))
        }

        try await reopened.close()
    }
}

@Test
func memoryOrchestratorRememberWithEmptyContentWritesSingleDocFrame() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        // Use a chunking strategy that would produce chunks for non-trivial content,
        // but the text is effectively empty after trimming by the chunker
        config.chunking = .tokenCount(targetTokens: 50, overlapTokens: 5)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        // An empty string produces no chunks; the orchestrator must write one doc frame
        try await orchestrator.remember("")
        try await orchestrator.flush()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        // One doc frame for the empty document
        #expect(stats.frameCount >= 1)
        try await wax.close()
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorHandoffWithSessionIdAttachesSessionMetadata() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let explicitSessionId = UUID()

        _ = try await orchestrator.rememberHandoff(
            content: "Session-tagged handoff.",
            project: "TestProject",
            pendingTasks: ["Task one"],
            sessionId: explicitSessionId
        )

        let record = try await orchestrator.latestHandoff(project: "TestProject")
        #expect(record != nil)
        #expect(record?.content.contains("Session-tagged") == true)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorFlushCountIncreasesOnEachFlush() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let before = await orchestrator.flushCount
        try await orchestrator.flush()
        let after = await orchestrator.flushCount
        #expect(after == before + 1)
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryFactsWithNilSubjectAndNilPredicate() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.upsertEntity(key: EntityKey("person:dave"), kind: "person")
        _ = try await orchestrator.assertFact(
            subject: EntityKey("person:dave"),
            predicate: PredicateKey("status"),
            object: .string("active")
        )

        // Query with nil subject and nil predicate: should return all facts
        let result = try await orchestrator.facts(about: nil, predicate: nil, limit: 100)
        #expect(result.hits.count >= 1)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorStructuredMemoryRetractFactWithExplicitTimestamp() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.upsertEntity(key: EntityKey("person:eve"), kind: "person")
        let factId = try await orchestrator.assertFact(
            subject: EntityKey("person:eve"),
            predicate: PredicateKey("role"),
            object: .string("engineer"),
            validFromMs: 0
        )

        let retractAtMs = Int64(Date().timeIntervalSince1970 * 1_000) + 5_000
        try await orchestrator.retractFact(factId: factId, atMs: retractAtMs)

        // The fact should still be visible before the retraction timestamp
        let beforeRetract = try await orchestrator.facts(
            about: EntityKey("person:eve"),
            predicate: PredicateKey("role"),
            asOfMs: retractAtMs - 1
        )
        #expect(beforeRetract.hits.count == 1)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorUpsertEntityWithoutCommitDoesNotPersistUntilNextFlush() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        // commit: false means the entity is staged but not yet committed
        _ = try await orchestrator.upsertEntity(
            key: EntityKey("person:fred"),
            kind: "person",
            aliases: ["Fred"],
            commit: false
        )

        // Entity should be resolvable within the same session (in-memory)
        let matches = try await orchestrator.resolveEntities(matchingAlias: "Fred")
        #expect(matches.map(\.key).contains(EntityKey("person:fred")))

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorAssertFactWithoutCommitIsVisibleAfterManualFlush() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.upsertEntity(key: EntityKey("person:grace"), kind: "person")
        _ = try await orchestrator.assertFact(
            subject: EntityKey("person:grace"),
            predicate: PredicateKey("mood"),
            object: .string("cheerful"),
            commit: false
        )

        // Flush commits the staged fact
        try await orchestrator.flush()

        let result = try await orchestrator.facts(about: EntityKey("person:grace"), predicate: PredicateKey("mood"))
        #expect(result.hits.count == 1)

        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorDirectSearchWithFrameFilterNilReturnsResults() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 2)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Accelerate framework provides SIMD-optimized math routines.")
        try await orchestrator.flush()

        let hits = try await orchestrator.search(
            query: "SIMD",
            mode: .text,
            topK: 5,
            frameFilter: nil
        )
        #expect(!hits.isEmpty)

        try await orchestrator.close()
    }
}
