import Foundation
import Testing
@testable import Wax
import WaxVectorSearch

@Suite("FoundationModelSessionCancellationTests")
struct FoundationModelSessionCancellationTests {
    @Test
    func searchWithFallbackRethrowsCancellationAndDoesNotTextFallback() async throws {
        try await TempFiles.withTempFile { url in
            var config = Memory.Config.default
            config.embedding = .custom(QueryCancelEmbedder())
            config.enableVectorSearch = true
            let memory = try await Memory(at: url, config: config)
            try await memory.save("User likes Vim keybindings.")

            let toolConfig = WaxMemoryToolConfig(
                embeddingPolicy: .always,
                fallbackToTextOnVectorFailure: true
            )
            do {
                _ = try await WaxMemoryToolExecutor.searchWithFallback(
                    memory: memory,
                    config: toolConfig,
                    query: "Vim",
                    topK: 3
                )
                Issue.record("CancellationError must not become a text-fallback success")
            } catch is CancellationError {
                // Expected after the catch-all is split.
            } catch {
                Issue.record("expected CancellationError, got \(error)")
            }

            try await memory.close()
        }
    }

    @Test
    func ifAvailableQueryEmbeddingPropagatesCancellation() async throws {
        try await TempFiles.withTempFile { url in
            var config = TestHelpers.defaultMemoryConfig(vector: true)
            let orchestrator = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: QueryCancelEmbedder()
            )
            try await orchestrator.remember("User likes Vim keybindings.")

            do {
                _ = try await orchestrator.recall(query: "Vim")
                Issue.record("ifAvailable must not swallow CancellationError as .failed")
            } catch is CancellationError {
                // Expected after the ifAvailable catch-all is split.
            } catch {
                Issue.record("expected CancellationError, got \(error)")
            }

            try await orchestrator.close()
        }
    }

#if canImport(FoundationModels)
    @Test
    func prepareRecallAndRespondRethrowQueryCancellationWithoutFallback() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            var memoryConfig = Memory.Config.default
            memoryConfig.embedding = .custom(QueryCancelEmbedder())
            memoryConfig.enableVectorSearch = true
            let memory = try await Memory(at: url, config: memoryConfig)
            try await memory.save("User favorite editor is Helix.")

            let generator = ControllableFoundationModelGenerator()
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .automatic
            configuration.persistencePolicy = .userAndAssistant
            configuration.includeMemoryTools = false
            configuration.contextStrategy = .promptAugmentation
            configuration.toolConfig.fallbackToTextOnVectorFailure = true

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            await #expect(throws: CancellationError.self) {
                _ = try await session.preparePromptDetailed(for: "editor")
            }
            await #expect(throws: CancellationError.self) {
                _ = try await session.recall(query: "editor")
            }
            await #expect(throws: CancellationError.self) {
                _ = try await session.respondDetailed(to: "editor")
            }
            #expect(await generator.generateCallCount() == 0)

            let hits = try await memory.search(
                "editor",
                options: .init(topK: 5, mode: .textOnly)
            )
            #expect(!hits.items.contains(where: { $0.text.localizedCaseInsensitiveContains("editor") && $0.text.count < 20 }))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellingRespondSurfacesCancellationAndStopsUnderlyingGeneration() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(blockUntilCancelled: true)
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .userAndAssistant
            configuration.includeMemoryTools = false
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let marker = "unique-cancel-turn-\(UUID().uuidString)"
            let task = Task {
                try await session.respondDetailed(to: marker)
            }
            try await Task.sleep(for: .milliseconds(40))
            #expect(await generator.isGenerating())
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await generator.didObserveCancellation())

            let hits = try await memory.search(
                marker,
                options: .init(topK: 5, mode: .textOnly)
            )
            #expect(!hits.items.contains(where: { $0.text.contains(marker) }))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellingDuringRecallPersistsNeitherSide() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            var memoryConfig = Memory.Config.default
            memoryConfig.embedding = .custom(QueryCancelEmbedder())
            memoryConfig.enableVectorSearch = true
            let memory = try await Memory(at: url, config: memoryConfig)
            try await memory.save("Durable fact about Helix stays.")

            let generator = ControllableFoundationModelGenerator()
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .automatic
            configuration.persistencePolicy = .userAndAssistant
            configuration.includeMemoryTools = false
            configuration.contextStrategy = .promptAugmentation
            configuration.toolConfig.fallbackToTextOnVectorFailure = true

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let marker = "unique-recall-cancel-\(UUID().uuidString)"
            await #expect(throws: CancellationError.self) {
                _ = try await session.respondDetailed(to: marker)
            }
            #expect(await generator.generateCallCount() == 0)

            let hits = try await memory.search(
                marker,
                options: .init(topK: 5, mode: .textOnly)
            )
            #expect(!hits.items.contains(where: { $0.text.contains(marker) }))

            try await session.close()
            try await memory.close()
        }
    }
#endif
}

private struct QueryCancelEmbedder: QueryAwareEmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "QueryCancel",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b: Float = 0.5
        let norm = (a * a + b * b).squareRoot()
        return [a / max(norm, 1e-6), b / max(norm, 1e-6)]
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        _ = text
        throw CancellationError()
    }
}
