#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Wax

@Suite("FoundationModelStreamingContractTests")
struct FoundationModelStreamingContractTests {
    @Test
    func normalConsumptionEmitsContentThenCompletedAndPersistsAfterFirstToken() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator()
            let session = makeStreamingSession(memory: memory, generator: generator)
            let marker = "unique-stream-normal-\(UUID().uuidString)"

            let stream = try await session.streamResponse(to: marker)
            var contents: [String] = []
            var completed: WaxFMResponse<String>?
            for try await event in stream {
                switch event {
                case .content(let text):
                    #expect(completed == nil, "content must arrive before completed")
                    contents.append(text)
                case .completed(let response):
                    completed = response
                }
            }

            #expect(!contents.isEmpty)
            let response = try #require(completed)
            #expect(response.content.contains(marker))
            #expect(response.didPersistUser)
            #expect(response.didPersistAssistant)
            #expect(try await countFrames(memory, query: marker, role: "user") == 1)
            #expect(try await countFrames(memory, query: "reply:", role: "assistant") >= 1)

            let followUp = try await withBoundedTimeout(description: "respond after normal stream") {
                try await session.respond(to: "after-normal-stream")
            }
            #expect(followUp.contains("after-normal-stream"))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellationBeforeFirstOutputPersistsNothingAndReleasesLease() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(pauseBeforeFirstChunk: true)
            let session = makeStreamingSession(memory: memory, generator: generator)
            let marker = "unique-stream-pre-output-\(UUID().uuidString)"

            let stream = try await session.streamResponse(to: marker)
            let consume = Task {
                for try await event in stream {
                    _ = event
                }
            }
            try await generator.waitUntilHoldingBeforeFirstChunk()
            #expect(try await countFrames(memory, query: marker, role: "user") == 0)

            consume.cancel()
            do {
                try await consume.value
                Issue.record("cancelled stream must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .cancelled(let didPersistUser, let didPersistAssistant) = error else {
                    Issue.record("expected .cancelled, got \(error)")
                    return
                }
                #expect(!didPersistUser)
                #expect(!didPersistAssistant)
            } catch is CancellationError {
                Issue.record("consumer cancel must be WaxFoundationModelsError.cancelled, not CancellationError")
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }

            #expect(try await countFrames(memory, query: marker, role: "user") == 0)
            #expect(try await countFrames(memory, query: "reply:", role: "assistant") == 0)

            let followUp = try await withBoundedTimeout(description: "respond after pre-output cancel") {
                try await session.respond(to: "after-pre-output-cancel")
            }
            #expect(followUp.contains("after-pre-output-cancel"))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellationAfterFirstOutputPersistsUserOnly() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(blockUntilCancelled: true)
            let session = makeStreamingSession(memory: memory, generator: generator)
            let marker = "unique-stream-post-output-\(UUID().uuidString)"

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

            consume.cancel()
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
                Issue.record("consumer cancel must be WaxFoundationModelsError.cancelled, not CancellationError")
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }

            try await memory.flush()
            #expect(try await countFrames(memory, query: marker, role: "user") == 1)
            #expect(try await countFrames(memory, query: "reply:", role: "assistant") == 0)

            let followUp = try await withBoundedTimeout(description: "respond after post-output cancel") {
                try await session.respond(to: "after-post-output-cancel")
            }
            #expect(followUp.contains("after-post-output-cancel"))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func droppingStreamReleasesLeaseWithoutPersistingUnansweredPrompt() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(pauseBeforeFirstChunk: true)
            let session = makeStreamingSession(memory: memory, generator: generator)
            let marker = "unique-stream-drop-\(UUID().uuidString)"

            var stream: WaxGenerationStream? = try await session.streamResponse(to: marker)
            try await generator.waitUntilHoldingBeforeFirstChunk()
            #expect(try await countFrames(memory, query: marker, role: "user") == 0)
            stream = nil

            let followUp = try await withBoundedTimeout(description: "respond after drop") {
                try await session.respond(to: "after-stream-drop")
            }
            #expect(followUp.contains("after-stream-drop"))
            #expect(try await countFrames(memory, query: marker, role: "user") == 0)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func guardrailFailureAfterFirstTokenPersistsUserNotAssistant() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(streamFailure: .afterFirstChunk)
            let session = makeStreamingSession(memory: memory, generator: generator)
            let marker = "unique-stream-guardrail-\(UUID().uuidString)"

            let stream = try await session.streamResponse(to: marker)
            var sawContent = false
            do {
                for try await event in stream {
                    if case .content = event {
                        sawContent = true
                    }
                }
                Issue.record("guardrail failure must throw")
            } catch is ControllableFoundationModelGuardrailError {
            } catch let error as WaxFoundationModelsError {
                guard case .generationFailed(let didPersistUser, let didPersistAssistant, _) = error else {
                    Issue.record("expected generationFailed, got \(error)")
                    return
                }
                #expect(didPersistUser)
                #expect(!didPersistAssistant)
            } catch {
                Issue.record("expected generationFailed, got \(error)")
            }
            #expect(sawContent)

            try await memory.flush()
            #expect(try await countFrames(memory, query: marker, role: "user") == 1)
            #expect(try await countFrames(memory, query: "reply:", role: "assistant") == 0)

            let followUp = try await withBoundedTimeout(description: "respond after guardrail") {
                try await session.respond(to: "after-guardrail")
            }
            #expect(followUp.contains("after-guardrail"))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func simultaneousStreamRequestThrowsGenerationInProgress() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(80))
            let session = makeStreamingSession(
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
                    Issue.record("expected WaxFoundationModelsError.generationInProgress, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxFoundationModelsError.generationInProgress, got \(error)")
            }

            var events = 0
            for try await _ in stream {
                events += 1
            }
            #expect(events >= 1)

            let after = try await session.streamResponse(to: "stream-C")
            var afterEvents = 0
            for try await _ in after {
                afterEvents += 1
            }
            #expect(afterEvents >= 1)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func secondIteratorIsInvalidated() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator()
            let session = makeStreamingSession(
                memory: memory,
                generator: generator,
                persistence: .none
            )

            let stream = try await session.streamResponse(to: "iterator-once")
            var first = stream.makeAsyncIterator()
            var second = stream.makeAsyncIterator()

            let firstEvent = try await first.next()
            #expect(firstEvent != nil)

            do {
                _ = try await second.next()
                Issue.record("second iterator must be invalidated")
            } catch let error as WaxFoundationModelsError {
                guard case .iteratorAlreadyCreated = error else {
                    Issue.record("expected iteratorAlreadyCreated, got \(error)")
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
    func streamResponseAndCollectUsesOwningStreamPersistenceOnCancel() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(blockUntilCancelled: true)
            let session = makeStreamingSession(memory: memory, generator: generator)
            let marker = "unique-collect-cancel-\(UUID().uuidString)"

            let task = Task {
                try await session.streamResponseAndCollect(to: marker)
            }
            try await generator.waitUntilGenerating()
            try await waitUntilFrameCount(memory, query: marker, role: "user", equals: 1)
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancelled collect must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .cancelled(let didPersistUser, let didPersistAssistant) = error else {
                    Issue.record("expected .cancelled, got \(error)")
                    return
                }
                #expect(didPersistUser)
                #expect(!didPersistAssistant)
            } catch is CancellationError {
                Issue.record("collect cancel must be WaxFoundationModelsError.cancelled, not CancellationError")
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }

            try await memory.flush()
            #expect(try await countFrames(memory, query: marker, role: "user") == 1)
            #expect(try await countFrames(memory, query: "reply:", role: "assistant") == 0)

            let followUp = try await withBoundedTimeout(description: "respond after collect cancel") {
                try await session.respond(to: "after-collect-cancel")
            }
            #expect(followUp.contains("after-collect-cancel"))

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancellingStreamDoesNotReleaseLeaseUntilUnderlyingRequestEnds() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(
                blockUntilCancelled: true,
                lingerAfterCancel: true
            )
            let session = makeStreamingSession(
                memory: memory,
                generator: generator,
                persistence: .none
            )

            let stream = try await session.streamResponse(to: "stream-linger")
            let (chunkSignal, chunkContinuation) = AsyncStream.makeStream(of: String.self)
            let consume = Task {
                for try await event in stream {
                    if case .content(let text) = event {
                        chunkContinuation.yield(text)
                        chunkContinuation.finish()
                    }
                }
            }

            _ = try await withBoundedTimeout(description: "first stream content") {
                var received: String?
                for await chunk in chunkSignal {
                    received = chunk
                    break
                }
                return received
            }
            try await generator.waitUntilGenerating()
            let streamGenerateCalls = await generator.generateCallCount()

            consume.cancel()
            do {
                try await consume.value
                Issue.record("cancelled stream must throw")
            } catch let error as WaxFoundationModelsError {
                guard case .cancelled = error else {
                    Issue.record("expected .cancelled, got \(error)")
                    return
                }
            } catch is CancellationError {
                Issue.record("consumer cancel must be WaxFoundationModelsError.cancelled, not CancellationError")
            } catch {
                Issue.record("expected WaxFoundationModelsError.cancelled, got \(error)")
            }

            try await generator.waitUntilLingeringAfterCancel()
            #expect(await generator.isUnderlyingRequestActive())

            let respondTask = Task {
                try await session.respond(to: "after-linger")
            }
            try await session.flush()
            do {
                try await waitUntilCondition(
                    timeout: .milliseconds(250),
                    description: "respond started during Apple teardown"
                ) {
                    await generator.generateCallCount() > streamGenerateCalls
                }
                Issue.record(
                    "next respond started while the cancelled Apple stream was still tearing down"
                )
            } catch is FoundationModelGeneratorWaitTimeout {
                // Expected: the generation lease stays held until linger ends.
            }
            #expect(await generator.generateCallCount() == streamGenerateCalls)
            #expect(await generator.isUnderlyingRequestActive())

            generator.releaseLingerAfterCancel()
            let reply = try await withBoundedTimeout(description: "respond after linger release") {
                try await respondTask.value
            }
            #expect(reply.contains("after-linger"))
            #expect(await generator.generateCallCount() == streamGenerateCalls + 1)
            #expect(await generator.maxInFlight() == 1)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func droppingStreamDoesNotReleaseLeaseUntilUnderlyingRequestEnds() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(
                pauseBeforeFirstChunk: true,
                lingerAfterCancel: true
            )
            let session = makeStreamingSession(
                memory: memory,
                generator: generator,
                persistence: .none
            )

            var stream: WaxGenerationStream? = try await session.streamResponse(to: "drop-linger")
            try await generator.waitUntilHoldingBeforeFirstChunk()
            stream = nil

            try await generator.waitUntilLingeringAfterCancel()
            #expect(await generator.isUnderlyingRequestActive())
            #expect(await generator.generateCallCount() == 0)

            let respondTask = Task {
                try await session.respond(to: "after-drop-linger")
            }
            try await session.flush()
            do {
                try await waitUntilCondition(
                    timeout: .milliseconds(250),
                    description: "respond started while dropped stream still owns Apple"
                ) {
                    await generator.generateCallCount() > 0
                }
                Issue.record(
                    "dropping a stream unlocked the generation gate before Apple was idle"
                )
            } catch is FoundationModelGeneratorWaitTimeout {
                // Expected: drop waits for the underlying request to finish.
            }
            #expect(await generator.generateCallCount() == 0)

            generator.releaseLingerAfterCancel()
            let reply = try await withBoundedTimeout(description: "respond after drop linger release") {
                try await respondTask.value
            }
            #expect(reply.contains("after-drop-linger"))
            #expect(await generator.maxInFlight() == 1)

            try await session.close()
            try await memory.close()
        }
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private func makeStreamingSession(
    memory: Memory,
    generator: ControllableFoundationModelGenerator,
    persistence: FoundationModelsMemorySessionConfig.PersistencePolicy = .userAndAssistant
) -> WaxFoundationModelSession {
    var configuration = FoundationModelsMemorySessionConfig.default
    configuration.embeddingPolicy = .never
    configuration.persistencePolicy = persistence
    configuration.contextStrategy = .promptAugmentation
    return WaxFoundationModelSession(
        memory: memory,
        configuration: configuration,
        generator: generator
    )
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private func countFrames(
    _ memory: Memory,
    query: String,
    role: String
) async throws -> Int {
    let hits = try await memory.search(query, options: .init(topK: 10, mode: .textOnly))
    return hits.items.filter { item in
        item.metadata["wax.role"] == role && item.text.contains(query)
    }.count
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private func waitUntilFrameCount(
    _ memory: Memory,
    query: String,
    role: String,
    equals expected: Int,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await countFrames(memory, query: query, role: role) == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    let actual = try await countFrames(memory, query: query, role: role)
    throw FoundationModelGeneratorWaitTimeout(
        "frame count \(role)/\(query) == \(expected) (got \(actual))"
    )
}
#endif
