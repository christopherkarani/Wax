import Foundation
import Testing
import Wax
import WaxTestSupport

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
func memoryOrchestratorStructuredMemoryDisabledThrowsFeatureDisabled() async throws {
    try await TempFiles.withTempFile { url in
        var config = TestHelpers.defaultMemoryConfig(vector: false)
        config.enableStructuredMemory = false
        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        do {
            _ = try await orchestrator.resolveEntities(matchingAlias: "alice")
            #expect(Bool(false), "structured memory lookup with the feature disabled must throw")
        } catch let error as WaxError {
            guard case .featureDisabled(let feature) = error else {
                #expect(Bool(false), "expected WaxError.featureDisabled, got \(error)")
                return
            }
            #expect(feature == "structured memory")
        } catch {
            #expect(Bool(false))
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorVectorStoreWithoutEmbedderThrowsMissingEmbedder() async throws {
    try await TempFiles.withTempFile { url in
        let config = TestHelpers.defaultMemoryConfig(vector: true)
        let seeded = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder(dimensions: 2)
        )
        try await seeded.remember("Seeded vector store phrase.")
        try await seeded.close()

        // Reopening a store that already has a committed vector index keeps vector
        // search enabled; writing without an embedder must fail with a typed error.
        let reopened = try await MemoryOrchestrator(at: url, config: config)
        do {
            try await reopened.remember("This write needs an embedder but none is configured.")
            #expect(Bool(false), "remember without embedder on a vector store must throw")
        } catch let error as WaxError {
            guard case .missingEmbedder = error else {
                #expect(Bool(false), "expected WaxError.missingEmbedder, got \(error)")
                return
            }
        } catch {
            #expect(Bool(false))
        }
        try await reopened.close()
    }
}

/// A custom provider's bad vector must fail the save that produced it and leave the store
/// usable: flush, close and the next open all succeed, and later good saves are searchable.
private func expectBadProviderVectorIsRejected(
    _ badProvider: any EmbeddingProvider,
    reasonContains expected: String,
    goodProvider: any EmbeddingProvider
) async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: .init(embedding: .custom(badProvider)))
        let longText = (0..<200).map { "chunk word \($0)" }.joined(separator: " ")
        for text in ["a single chunk note", longText] {
            do {
                try await memory.save(text)
                Issue.record("save must reject the provider's vector")
            } catch let WaxError.encodingError(reason) {
                #expect(reason.contains(expected), "\(reason)")
            }
        }
        try await memory.flush()
        try await memory.close()

        let reopened = try await Memory(at: url, config: .init(embedding: .custom(badProvider)))
        try await reopened.close()

        let good = try await Memory(at: url, config: .init(embedding: .custom(goodProvider)))
        try await good.save("a good note after the rejected ones")
        try await good.flush()
        let results = try await good.search("a good note after the rejected ones", options: .init(topK: 1, mode: .vectorOnly))
        #expect(results.items.first?.text == "a good note after the rejected ones")
        try await good.close()
    }
}

@Test
func memoryCustomProviderNonFiniteVectorIsRejectedAndStoreStaysUsable() async throws {
    try await expectBadProviderVectorIsRejected(
        ConstantEmbedder(vector: [.nan, 0.5], provider: "Mock", model: "DeterministicText", normalized: false),
        reasonContains: "non-finite",
        goodProvider: DeterministicTextEmbedder()
    )
}

@Test
func memoryCustomProviderWrongDimensionVectorIsRejectedAndStoreStaysUsable() async throws {
    // Declares 4 dimensions but always returns 2 components.
    try await expectBadProviderVectorIsRejected(
        DeterministicTextEmbedder(dimensions: 4, identity: EmbeddingIdentity(
            provider: "Mock",
            model: "DeterministicText",
            dimensions: 4,
            normalized: true
        )),
        reasonContains: "declares 4",
        goodProvider: SeededHashEmbedder(dimensions: 4, provider: "Mock")
    )
}
