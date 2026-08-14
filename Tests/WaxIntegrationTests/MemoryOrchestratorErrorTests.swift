import Foundation
import Testing
import Wax

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
func memoryOrchestratorVectorStoreWithoutEmbedderDegradesToTextOnly() async throws {
    try await TempFiles.withTempFile { url in
        let config = TestHelpers.defaultMemoryConfig(vector: true)
        let seeded = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder(dimensions: 2)
        )
        try await seeded.remember("Seeded vector store phrase.")
        try await seeded.close()

        // Reopening without a provider must keep text writes available while making
        // the disabled vector lane explicit in runtime health.
        let reopened = try await MemoryOrchestrator(at: url, config: config)
        try await reopened.remember("This write remains available in text-only mode.")
        let runtime = await reopened.runtimeStats()
        #expect(!runtime.vectorSearchEnabled)
        #expect(!runtime.queryEmbedderConfigured)
        try await reopened.close()
    }
}
