import Foundation
import Testing
import Wax

@Suite("PublicErrorContractTests")
struct PublicErrorContractTests {
    @Test
    func vectorOnlySearchWithVectorSearchDisabledThrowsFeatureDisabled() async throws {
        try await TempFiles.withTempFile { url in
            let config = Memory.Config(enableVectorSearch: false)
            let memory = try await Memory(at: url, config: config)
            do {
                _ = try await memory.search("query", options: .init(mode: .vectorOnly))
                Issue.record("vector-only search with vector search disabled must throw")
            } catch let error as WaxError {
                guard case .featureDisabled(let feature) = error else {
                    Issue.record("expected WaxError.featureDisabled, got \(error)")
                    return
                }
                #expect(feature == "vector search")
            } catch {
                Issue.record("expected WaxError, got \(error)")
            }
            try await memory.close()
        }
    }

    @Test
    func vectorStoreWithoutEmbedderThrowsMissingEmbedder() async throws {
        try await TempFiles.withTempFile { url in
            let seedConfig = Memory.Config(embedding: .custom(DeterministicTextEmbedder()))
            let seeded = try await Memory(at: url, config: seedConfig)
            try await seeded.save("Seeded vector store phrase.")
            try await seeded.flush()
            try await seeded.close()

            // Public Memory.Config.embedding has no "none" case; MiniLM auto-wire would
            // supply a provider. Reopen through MemoryOrchestrator with vector search
            // still enabled (existing index) and no embedder, then observe via Memory.
            var orchConfig = OrchestratorConfig.default
            orchConfig.enableVectorSearch = true
            let orchestrator = try await MemoryOrchestrator(at: url, config: orchConfig)
            let memory = Memory(orchestrator: orchestrator)
            do {
                try await memory.save("This write needs an embedder but none is configured.")
                Issue.record("save without embedder on a vector store must throw")
            } catch let error as WaxError {
                guard case .missingEmbedder = error else {
                    Issue.record("expected WaxError.missingEmbedder, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxError, got \(error)")
            }
            try await memory.close()
        }
    }

    @Test
    func wrongDimensionEmbeddingThrowsInvalidEmbeddingDuringSave() async throws {
        try await expectInvalidEmbeddingOnSave(
            embedder: WrongDimensionTextEmbedder()
        )
    }

    @Test
    func nonFiniteEmbeddingThrowsInvalidEmbeddingDuringSave() async throws {
        try await expectInvalidEmbeddingOnSave(
            embedder: NonFiniteTextEmbedder()
        )
    }

    @Test
    func zeroVectorFromNormalizedProviderThrowsInvalidEmbeddingDuringSave() async throws {
        try await expectInvalidEmbeddingOnSave(
            embedder: ZeroVectorTextEmbedder()
        )
    }

    @Test
    func invalidConfigurationErrorDescriptionIsTyped() {
        let error = WaxError.invalidConfiguration(reason: "WAL size must be greater than zero")
        #expect(error.errorDescription?.contains("Invalid configuration") == true)
        #expect(error.errorDescription?.contains("WAL size must be greater than zero") == true)
        if case .invalidConfiguration(let reason) = error {
            #expect(reason == "WAL size must be greater than zero")
        } else {
            Issue.record("expected WaxError.invalidConfiguration")
        }
    }
}

private struct NonFiniteTextEmbedder: EmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "NonFinite",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [.nan, 1]
    }
}

private struct ZeroVectorTextEmbedder: EmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "ZeroVector",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [0, 0]
    }
}

private func expectInvalidEmbeddingOnSave(embedder: any EmbeddingProvider) async throws {
    try await TempFiles.withTempFile { url in
        let config = Memory.Config(embedding: .custom(embedder))
        let memory = try await Memory(at: url, config: config)
        do {
            try await memory.save("Invalid embedding must fail during save, not flush.")
            Issue.record("save must throw for an invalid embedding")
        } catch let error as WaxError {
            if case .invalidEmbedding = error {
                // Expected typed failure before any frame write.
            } else {
                Issue.record("expected WaxError.invalidEmbedding, got \(error)")
            }
        } catch {
            Issue.record("expected WaxError, got \(error)")
        }

        let stats = await memory.stats()
        #expect(stats.frameCount == 0)
        do {
            try await memory.close()
        } catch {
            Issue.record("close after invalid save threw \(error)")
        }

        let reopened = try await Memory(at: url, config: config)
        let reopenedStats = await reopened.stats()
        #expect(reopenedStats.frameCount == 0)
        try await reopened.close()
    }
}
