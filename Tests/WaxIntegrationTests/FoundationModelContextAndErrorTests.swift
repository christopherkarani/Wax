#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Wax

@Suite("FoundationModelContextAndErrorTests")
struct FoundationModelContextAndErrorTests {
    @Test
    func availabilityMapsAppleReasonsWithoutOverclaiming() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        #expect(
            WaxFoundationModelsAvailability.map(.available) == .available
        )
        #expect(
            WaxFoundationModelsAvailability.map(.unavailable(.deviceNotEligible))
                == .unavailable(.deviceNotEligible)
        )
        #expect(
            WaxFoundationModelsAvailability.map(.unavailable(.appleIntelligenceNotEnabled))
                == .unavailable(.appleIntelligenceNotEnabled)
        )
        #expect(
            WaxFoundationModelsAvailability.map(.unavailable(.modelNotReady))
                == .unavailable(.modelNotReady)
        )

        let current = WaxFoundationModelsAvailability.current()
        switch current {
        case .available:
            break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unknown:
                break
            }
        }
    }

    @Test
    func preflightThrowsTypedUnavailableBeforeSessionWork() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        let reasons: [WaxFoundationModelsAvailability.UnavailableReason] = [
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unknown("custom-unavailable"),
        ]
        for reason in reasons {
            do {
                try WaxFoundationModelsAvailability.preflight(.unavailable(reason))
                Issue.record("preflight must throw for \(reason)")
            } catch let error as WaxFoundationModelsError {
                guard case .unavailable(let observed) = error else {
                    Issue.record("expected .unavailable, got \(error)")
                    return
                }
                #expect(observed == reason)
            } catch {
                Issue.record("expected WaxFoundationModelsError.unavailable, got \(error)")
            }
        }
    }

    @Test
    func makeFoundationModelsSessionPrefLightsAvailability() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            switch WaxFoundationModelsAvailability.current() {
            case .available:
                let session = try await memory.makeFoundationModelsSession(
                    instructions: "Be concise.",
                    configuration: .promptOnlyLight
                )
                #expect(session.ownsMemoryStore == false)
                try await session.close()
            case .unavailable(let reason):
                do {
                    _ = try await memory.makeFoundationModelsSession()
                    Issue.record("makeFoundationModelsSession must fail when unavailable")
                } catch let error as WaxFoundationModelsError {
                    guard case .unavailable(let observed) = error else {
                        Issue.record("expected .unavailable, got \(error)")
                        return
                    }
                    #expect(observed == reason)
                } catch {
                    Issue.record("expected WaxFoundationModelsError.unavailable, got \(error)")
                }
            }
            try await memory.close()
        }
    }

    @Test
    func preparedPromptOverflowThrowsMeasuredContextWindowExceeded() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let fact = "User mission dossier: " + String(repeating: "alpha-token-", count: 40)
            try await memory.save(fact)

            var configuration = FoundationModelsMemorySessionConfig.promptOnlyLight
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.promptBuilder = FoundationModelsMemoryPromptBuilder(
                maxItems: 4,
                maxMemoryCharacters: 8_000,
                injectionStyle: .xmlTags
            )
            configuration.contextPolicy = WaxFoundationModelsContextPolicy(
                maxPreparedCharacters: 80,
                maxConversationTurns: 8,
                overflowPolicy: .fail
            )

            let generator = ControllableFoundationModelGenerator()
            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )
            let userPrompt = "Summarize the mission dossier in one sentence."

            do {
                _ = try await session.preparePromptDetailed(for: userPrompt)
                Issue.record("preparePromptDetailed must throw when the prepared prompt exceeds the character bound")
            } catch let error as WaxFoundationModelsError {
                guard case .contextWindowExceeded(
                    let estimatedPreparedCharacters,
                    let maxPreparedCharacters,
                    let estimatedContextTokens,
                    let recalledItemCount
                ) = error else {
                    Issue.record("expected .contextWindowExceeded, got \(error)")
                    return
                }
                #expect(maxPreparedCharacters == 80)
                #expect(estimatedPreparedCharacters > 80)
                #expect(estimatedContextTokens >= 0)
                #expect(recalledItemCount >= 1)
                #expect(await generator.generateCallCount() == 0)
            } catch {
                Issue.record("expected WaxFoundationModelsError.contextWindowExceeded, got \(error)")
            }

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func appleExceededContextWindowMapsAndRetryResetsTranscriptOnce() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let appleOverflow = LanguageModelSession.GenerationError.exceededContextWindowSize(
                .init(debugDescription: "synthetic overflow")
            )

            var failConfig = FoundationModelsMemorySessionConfig.promptOnlyLight
            failConfig.embeddingPolicy = .never
            failConfig.persistencePolicy = .userAndAssistant
            failConfig.contextPolicy.overflowPolicy = .fail
            let failingGenerator = ControllableFoundationModelGenerator(generateError: appleOverflow)
            let failingSession = WaxFoundationModelSession(
                memory: memory,
                configuration: failConfig,
                generator: failingGenerator
            )
            let marker = "unique-apple-overflow-\(UUID().uuidString)"
            do {
                _ = try await failingSession.respondDetailed(to: marker)
                Issue.record("Apple exceeded-context-window must map to .contextWindowExceeded")
            } catch let error as WaxFoundationModelsError {
                guard case .contextWindowExceeded = error else {
                    Issue.record("expected .contextWindowExceeded, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxFoundationModelsError.contextWindowExceeded, got \(error)")
            }
            #expect(await failingGenerator.generateCallCount() == 1)
            #expect(try await countRoleFrames(memory, query: marker, role: "user") == 0)

            var retryConfig = failConfig
            retryConfig.contextPolicy.overflowPolicy = .resetTranscriptAndRetryOnce
            let retryGenerator = ControllableFoundationModelGenerator(
                generateError: appleOverflow,
                generateErrorCount: 1
            )
            let retrySession = WaxFoundationModelSession(
                memory: memory,
                configuration: retryConfig,
                generator: retryGenerator
            )
            let retryMarker = "unique-apple-overflow-retry-\(UUID().uuidString)"
            let response = try await retrySession.respondDetailed(to: retryMarker)
            #expect(response.resetTranscriptForContext)
            #expect(response.didPersistUser)
            #expect(response.didPersistAssistant)
            #expect(await retryGenerator.generateCallCount() == 2)
            #expect(try await countRoleFrames(memory, query: retryMarker, role: "user") == 1)

            try await failingSession.close()
            try await retrySession.close()
            try await memory.close()
        }
    }

    @Test
    func toolsStrategyCannotDisableMemoryTools() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        var configuration = FoundationModelsMemorySessionConfig.toolsOnlyCompact
        #expect(configuration.contextStrategy == .tools)
        #expect(configuration.includeMemoryTools == true)

        configuration.contextStrategy = .promptAugmentation
        #expect(configuration.includeMemoryTools == false)
        configuration.contextStrategy = .hybrid
        #expect(configuration.includeMemoryTools == true)
    }

    @Test
    func secondStreamThrowsGenerationInProgressNotWriterBusy() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(80))
            let session = makePromptOnlySession(
                memory: memory,
                generator: generator,
                persistence: .none
            )

            let stream = try await session.streamResponse(to: "stream-A")
            do {
                _ = try await session.streamResponse(to: "stream-B")
                Issue.record("second stream must fail while the first is active")
            } catch let error as WaxFoundationModelsError {
                guard case .generationInProgress = error else {
                    Issue.record("expected .generationInProgress, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxFoundationModelsError.generationInProgress, got \(error)")
            }

            for try await _ in stream {}
            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func secondIteratorThrowsIteratorAlreadyCreatedNotInvalidConfiguration() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator()
            let session = makePromptOnlySession(
                memory: memory,
                generator: generator,
                persistence: .none
            )

            let stream = try await session.streamResponse(to: "iterator-once")
            var first = stream.makeAsyncIterator()
            var second = stream.makeAsyncIterator()
            #expect(try await first.next() != nil)

            do {
                _ = try await second.next()
                Issue.record("second iterator must be invalidated")
            } catch let error as WaxFoundationModelsError {
                guard case .iteratorAlreadyCreated = error else {
                    Issue.record("expected .iteratorAlreadyCreated, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxFoundationModelsError.iteratorAlreadyCreated, got \(error)")
            }

            while try await first.next() != nil {}
            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellationAfterFirstStreamTokenCarriesPersistenceAccounting() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(blockUntilCancelled: true)
            let session = makePromptOnlySession(memory: memory, generator: generator)
            let marker = "unique-cancel-accounting-\(UUID().uuidString)"

            let stream = try await session.streamResponse(to: marker)
            let (chunkSignal, chunkContinuation) = AsyncStream.makeStream(of: String.self)
            let consume = Task {
                for try await event in stream {
                    if case .content(let text) = event {
                        chunkContinuation.yield(text)
                        chunkContinuation.finish()
                    }
                }
            }

            let firstChunk = try await withBoundedTimeout(description: "first stream content") {
                var received: String?
                for await chunk in chunkSignal {
                    received = chunk
                    break
                }
                return received
            }
            #expect(firstChunk != nil)
            try await generator.waitUntilGenerating()
            generator.requestCancellation()

            do {
                try await consume.value
                Issue.record("cancelled stream must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .cancelled(let didPersistUser, let didPersistAssistant) = error else {
                    Issue.record("expected .cancelled, got \(error)")
                    return
                }
                #expect(didPersistUser)
                #expect(!didPersistAssistant)
            } catch is CancellationError {
                Issue.record("cancellation must be WaxFoundationModelsError.cancelled, not CancellationError")
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }

            try await memory.flush()
            #expect(try await countRoleFrames(memory, query: marker, role: "user") == 1)
            #expect(try await countRoleFrames(memory, query: "reply:", role: "assistant") == 0)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func generationFailureAfterFirstTokenCarriesPersistenceAccounting() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(streamFailure: .afterFirstChunk)
            let session = makePromptOnlySession(memory: memory, generator: generator)
            let marker = "unique-fail-accounting-\(UUID().uuidString)"

            let stream = try await session.streamResponse(to: marker)
            do {
                for try await _ in stream {}
                Issue.record("guardrail failure must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .generationFailed(let didPersistUser, let didPersistAssistant, _) = error else {
                    Issue.record("expected .generationFailed, got \(error)")
                    return
                }
                #expect(didPersistUser)
                #expect(!didPersistAssistant)
            } catch {
                Issue.record("expected WaxFoundationModelsError.generationFailed, got \(error)")
            }

            try await memory.flush()
            #expect(try await countRoleFrames(memory, query: marker, role: "user") == 1)
            #expect(try await countRoleFrames(memory, query: "reply:", role: "assistant") == 0)

            try await session.close()
            try await memory.close()
        }
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private func makePromptOnlySession(
    memory: Memory,
    generator: ControllableFoundationModelGenerator,
    persistence: FoundationModelsMemorySessionConfig.PersistencePolicy = .userAndAssistant
) -> WaxFoundationModelSession {
    var configuration = FoundationModelsMemorySessionConfig.promptOnlyLight
    configuration.embeddingPolicy = .never
    configuration.persistencePolicy = persistence
    return WaxFoundationModelSession(
        memory: memory,
        configuration: configuration,
        generator: generator
    )
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private func countRoleFrames(
    _ memory: Memory,
    query: String,
    role: String
) async throws -> Int {
    let hits = try await memory.search(query, options: .init(topK: 10, mode: .textOnly))
    return hits.items.filter { item in
        item.metadata["wax.role"] == role && item.text.contains(query)
    }.count
}
#endif
