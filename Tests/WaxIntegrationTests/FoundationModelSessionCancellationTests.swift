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
            defer { task.cancel() }
            try await generator.waitUntilGenerating()
            #expect(await generator.isGenerating())
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancelled respond must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .cancelled(let didPersistUser, let didPersistAssistant) = error else {
                    Issue.record("expected .cancelled, got \(error)")
                    return
                }
                #expect(!didPersistUser)
                #expect(!didPersistAssistant)
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }
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

    @Test
    func cancellingAfterGenerationBeforePersistenceWritesNeitherSideAndRetryIsNotDuplicate() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(pauseBeforePersistence: true)
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .userAndAssistant
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let marker = "unique-persist-cancel-\(UUID().uuidString)"
            let task = Task {
                try await session.respondDetailed(to: marker)
            }
            defer { task.cancel() }
            try await generator.waitUntilPersistenceHold()
            #expect(await generator.generateCallCount() == 1)
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("persist-window cancel must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .cancelled(let didPersistUser, let didPersistAssistant) = error else {
                    Issue.record("expected .cancelled, got \(error)")
                    return
                }
                #expect(!didPersistUser)
                #expect(!didPersistAssistant)
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }

            let cancelledHits = try await memory.search(
                marker,
                options: .init(topK: 10, mode: .textOnly)
            )
            #expect(cancelledHits.items.filter { $0.text.contains(marker) }.isEmpty)

            let retry = try await session.respondDetailed(to: marker)
            #expect(retry.didPersistUser)
            #expect(retry.didPersistAssistant)
            #expect(await generator.generateCallCount() == 2)

            try await memory.flush()
            let retriedHits = try await memory.search(
                marker,
                options: .init(topK: 10, mode: .textOnly)
            )
            let userFrames = retriedHits.items.filter {
                $0.metadata["wax.role"] == "user" && $0.text.contains(marker)
            }
            #expect(userFrames.count == 1)

            let assistantHits = try await memory.search(
                "reply",
                options: .init(topK: 10, mode: .textOnly)
            )
            let assistantFrames = assistantHits.items.filter {
                $0.metadata["wax.role"] == "assistant" && $0.text.hasPrefix("reply:")
            }
            #expect(assistantFrames.count == 1)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellingStreamConsumptionReleasesGenerationLease() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(blockUntilCancelled: true)
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let stream = try await session.streamResponse(to: "stream-cancel")
            let (chunkSignal, chunkContinuation) = AsyncStream.makeStream(of: String.self)
            let consume = Task {
                var chunks: [String] = []
                for try await event in stream {
                    if case .content(let chunk) = event {
                        chunks.append(chunk)
                        if chunks.count == 1 {
                            chunkContinuation.yield(chunk)
                            chunkContinuation.finish()
                        }
                    }
                }
                return chunks
            }

            let firstChunk = try await withBoundedTimeout(description: "first stream chunk") {
                var received: String?
                for await chunk in chunkSignal {
                    received = chunk
                    break
                }
                return received
            }
            #expect(firstChunk != nil)
            try await generator.waitUntilGenerating()

            consume.cancel()
            do {
                _ = try await consume.value
            } catch is CancellationError {
            } catch {
                // Stream termination may surface as a wrapped cancellation.
            }

            let reply = try await withBoundedTimeout(description: "respond after stream cancel") {
                try await session.respond(to: "after-stream-cancel")
            }
            #expect(reply.contains("after-stream-cancel"))

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
