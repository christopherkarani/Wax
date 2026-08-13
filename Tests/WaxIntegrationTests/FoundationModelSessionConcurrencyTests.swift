#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Wax

@Suite("FoundationModelSessionConcurrencyTests")
struct FoundationModelSessionConcurrencyTests {
    @Test
    func twoConcurrentRespondCallsNeverOverlap() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(80))
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            async let first = session.respond(to: "first")
            async let second = session.respond(to: "second")
            let (firstReply, secondReply) = try await (first, second)

            #expect(firstReply.contains("first"))
            #expect(secondReply.contains("second"))
            #expect(await generator.maxInFlight() == 1)
            #expect(await generator.completedPrompts() == ["first", "second"])

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func streamConsumptionHoldsGenerationLease() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(120))
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let stream = try await session.streamResponse(to: "stream-A")
            let second = Task { try await session.respond(to: "respond-B") }
            try await generator.waitUntilGenerating()
            #expect(await generator.maxInFlight() == 1)
            #expect(await generator.completedPrompts().isEmpty)

            var chunks: [String] = []
            for try await event in stream {
                if case .content(let chunk) = event {
                    chunks.append(chunk)
                }
            }
            #expect(!chunks.isEmpty)
            _ = try await second.value

            #expect(await generator.maxInFlight() == 1)
            #expect(await generator.completedPrompts() == ["stream-A", "respond-B"])

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func streamResponseAndCollectSerializesWithRespond() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(80))
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            async let collected = session.streamResponseAndCollect(to: "collect-A")
            async let plain = session.respond(to: "respond-B")
            let (collectedReply, plainReply) = try await (collected, plain)

            #expect(collectedReply.content.contains("collect-A"))
            #expect(plainReply.contains("respond-B"))
            #expect(await generator.maxInFlight() == 1)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func cancelledStreamWaiterDoesNotBlockLaterStreams() async throws {
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

            let respondTask = Task {
                try await session.respond(to: "hold-gate")
            }
            try await generator.waitUntilGenerating()

            let waitingOutcome = TaskOutcome<WaxGenerationStream>()
            let waitingStream = Task {
                do {
                    let stream = try await session.streamResponse(to: "waiting-stream")
                    waitingOutcome.set(.success(stream))
                    return stream
                } catch {
                    waitingOutcome.set(.failure(error))
                    throw error
                }
            }
            try await waitUntilCondition(description: "stream waiter entered session") {
                try? await session.flush()
                return waitingStream.isCancelled == false
            }
            try await session.flush()
            try await session.flush()

            waitingStream.cancel()
            do {
                try await waitUntilCondition(
                    timeout: .milliseconds(400),
                    description: "cancelled stream waiter unblocked"
                ) {
                    waitingOutcome.snapshot() != nil
                }
            } catch is FoundationModelGeneratorWaitTimeout {
                Issue.record("cancelled stream waiter stayed blocked on the mutex")
                respondTask.cancel()
                _ = await respondTask.result
                try await session.close()
                try await memory.close()
                return
            }

            switch waitingOutcome.snapshot() {
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error as WaxFoundationModelsError):
                guard case .cancelled = error else {
                    Issue.record("expected CancellationError or .cancelled, got \(error)")
                    respondTask.cancel()
                    _ = await respondTask.result
                    try await session.close()
                    try await memory.close()
                    return
                }
            case .success:
                Issue.record("cancelled stream waiter must throw")
            case .failure(let error):
                Issue.record("expected CancellationError or .cancelled, got \(error)")
            case .none:
                Issue.record("cancelled stream waiter produced no result")
            }

            #expect(await generator.isGenerating())

            let retryOutcome = TaskOutcome<WaxGenerationStream>()
            let retryStream = Task {
                do {
                    let stream = try await session.streamResponse(to: "retry-stream")
                    retryOutcome.set(.success(stream))
                    return stream
                } catch {
                    retryOutcome.set(.failure(error))
                    throw error
                }
            }
            try await session.flush()
            do {
                try await waitUntilCondition(
                    timeout: .milliseconds(200),
                    description: "retry stream either failed fast or queued"
                ) {
                    retryOutcome.snapshot() != nil
                }
                if case .failure(let error as WaxFoundationModelsError) = retryOutcome.snapshot(),
                   case .generationInProgress = error {
                    Issue.record(
                        "cancelled stream waiter left isStreaming set; retry threw generationInProgress"
                    )
                }
            } catch is FoundationModelGeneratorWaitTimeout {
                // Still waiting on the in-flight respond — the fail-fast flag is clear.
            }

            respondTask.cancel()
            _ = await respondTask.result

            let stream = try await withBoundedTimeout(description: "retry stream after respond ends") {
                try await retryStream.value
            }
            var events = 0
            for try await _ in stream {
                events += 1
            }
            #expect(events >= 1)

            try await session.close()
            try await memory.close()
        }
    }
}
#endif
