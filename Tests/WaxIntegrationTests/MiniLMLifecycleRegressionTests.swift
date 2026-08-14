import Foundation
import Testing
import Wax
import WaxCore

@Test
func embeddingLoadCoordinatorRetainsColdLoadAfterFirstWaiterTimesOut() async throws {
    let counter = EmbeddingFactoryCounter()
    let coordinator = EmbeddingLoadCoordinator()
    let key = EmbeddingLoadKey(provider: "minilm", configuration: "default")

    await #expect(throws: EmbeddingLoadCoordinator.WaitError.timedOut) {
        _ = try await coordinator.provider(
            for: key,
            timeout: .milliseconds(10)
        ) {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return DeterministicTextEmbedder()
        }
    }

    let provider = try await coordinator.provider(
        for: key,
        timeout: .seconds(1)
    ) {
        await counter.increment()
        return DeterministicTextEmbedder(dimensions: 4)
    }

    #expect(provider.dimensions == 2)
    #expect(await counter.value == 1)
}

@Test
func memoryAutomaticEmbeddingLoadsInBackgroundAndBackfillsEarlyText() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(
            at: url,
            config: .init(enableVectorSearch: true, embedding: .automatic)
        ) {
            try await Task.sleep(for: .milliseconds(150))
            return DeterministicTextEmbedder()
        }

        let loading = await memory.stats()
        #expect(loading.embeddingStatus == .loading)
        #expect(!loading.vectorSearchEnabled)
        try await memory.save("The recovery phrase is silver-comet.")

        let status = await memory.prepareEmbeddings()
        guard case .active = status else {
            Issue.record("Expected active embeddings, got \(status)")
            return
        }

        let active = await memory.stats()
        #expect(active.vectorSearchEnabled)
        #expect(active.queryEmbedderConfigured)
        #expect(active.embeddingStatus == .active(DeterministicTextEmbedder().identity))

        let result = try await memory.search(
            "The recovery phrase is silver-comet.",
            options: .init(topK: 1, mode: .vectorOnly)
        )
        #expect(result.items.first?.text.contains("silver-comet") == true)
        try await memory.close()
    }
}

@Test
func memoryCloseDuringAutomaticBackfillDoesNotResumeWorkOnClosedStore() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = HangingCountingEmbedder()
        let memory = try await Memory(
            at: url,
            config: .init(enableVectorSearch: true, embedding: .automatic)
        ) {
            try await Task.sleep(for: .milliseconds(250))
            return embedder
        }
        try await memory.save("Text queued before the model is ready.")

        for _ in 0..<100 {
            if await embedder.callCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await embedder.callCount() == 1)

        try await AsyncTimeout.run(timeout: .seconds(1), operation: "memory close") {
            try await memory.close()
        }
    }
}

@Test
func memoryOrchestratorCanActivateEmbedderAndBackfillTextSavedWhileLoading() async throws {
    try await TempFiles.withTempFile { url in
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: 128, overlapTokens: 0)

        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: nil
        )

        try await orchestrator.remember("The launch code is violet-orchid.")

        let before = await orchestrator.runtimeStats()
        #expect(!before.vectorSearchEnabled)
        #expect(!before.queryEmbedderConfigured)

        let embedder = DeterministicTextEmbedder()
        try await orchestrator.activateEmbedder(embedder)
        let backfilled = try await orchestrator.backfillMissingEmbeddings()
        try await orchestrator.flush()

        #expect(backfilled == 1)

        let after = await orchestrator.runtimeStats()
        #expect(after.vectorSearchEnabled)
        #expect(after.queryEmbedderConfigured)
        #expect(after.embedderIdentity == embedder.identity)

        let embedding = try await embedder.embed("The launch code is violet-orchid.")
        let context = try await orchestrator.recall(
            query: "launch code",
            embedding: embedding
        )
        #expect(context.items.first?.text.contains("violet-orchid") == true)

        try await orchestrator.close()
    }
}

@Test
func memoryWrapperReportsActiveOrchestratorEmbeddingStatus() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder()
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: TestHelpers.defaultMemoryConfig(vector: true),
            embedder: embedder
        )
        let memory = Memory(orchestrator: orchestrator)

        #expect(await memory.stats().embeddingStatus == .active(embedder.identity))
        #expect(await memory.prepareEmbeddings() == .active(embedder.identity))
        try await memory.close()
    }
}

@Test
func reopeningVectorStoreWithoutEmbedderDegradesToWritableTextOnlyMode() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder()
        let config = TestHelpers.defaultMemoryConfig(vector: true)

        do {
            let seeded = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: embedder
            )
            try await seeded.remember("A vector-backed memory.")
            try await seeded.close()
        }

        let reopened = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: nil
        )
        try await reopened.remember("Text remains writable while the model is unavailable.")

        let stats = await reopened.runtimeStats()
        #expect(!stats.vectorSearchEnabled)
        #expect(!stats.queryEmbedderConfigured)
        try await reopened.close()
    }
}

private actor EmbeddingFactoryCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Test
func builtInEmbeddingDefaultsExcludeKnownBrokenCpuOnlyPath() {
    #expect(!BuiltInEmbeddingProviderOptions.default.computeUnitsOrder.contains(.cpuOnly))
}
