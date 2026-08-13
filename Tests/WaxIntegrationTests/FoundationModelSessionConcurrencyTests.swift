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
            try await waitUntilCondition(description: "stream waiter parked on generation gate") {
                await session.generationGateWaiterCount() > 0
            }

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

    @Test
    func preparePromptDetailedDoesNotOverwriteInFlightGenerationAccounting() async throws {
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

            let inFlightPrompt = "in-flight-prompt-gate-\(UUID().uuidString)"
            let otherPrompt = "other-prompt-gate-\(UUID().uuidString)"
            let respondTask = Task {
                try await session.respond(to: inFlightPrompt)
            }
            try await generator.waitUntilPersistenceHold()
            let duringHold = await session.lastPreparedPrompt
            #expect(duringHold?.prompt.contains(inFlightPrompt) == true)

            let prepareOutcome = TaskOutcome<PreparedMemoryPrompt>()
            let prepareTask = Task {
                do {
                    let prepared = try await session.preparePromptDetailed(for: otherPrompt)
                    prepareOutcome.set(.success(prepared))
                    return prepared
                } catch {
                    prepareOutcome.set(.failure(error))
                    throw error
                }
            }
            try await Task.sleep(for: .milliseconds(80))
            #expect(prepareOutcome.snapshot() == nil)
            #expect(await session.lastPreparedPrompt?.prompt.contains(inFlightPrompt) == true)

            respondTask.cancel()
            _ = await respondTask.result
            let prepared = try await withBoundedTimeout(description: "queued prepare after generation") {
                try await prepareTask.value
            }
            #expect(prepared.prompt.contains(otherPrompt))
            #expect(await session.lastPreparedPrompt?.prompt.contains(otherPrompt) == true)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func preparePromptDetailedFromToolDuringRespondDoesNotDeadlock() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            let nestedPrompt = "nested-tool-prepare-\(UUID().uuidString)"
            let hook = NestedPrepareHook()
            let generator = ControllableFoundationModelGenerator(delay: .milliseconds(20)) {
                try await hook.prepareNested(for: nestedPrompt)
            }
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )
            hook.setSession(session)

            let reply = try await withBoundedTimeout(description: "respond with nested preparePromptDetailed") {
                try await session.respond(to: "outer-prompt")
            }
            #expect(reply.contains("outer-prompt"))
            #expect(hook.didPrepare)
            #expect(await session.lastPreparedPrompt?.prompt.contains(nestedPrompt) == true)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func independentPreparePromptDetailedCallsStillSerialize() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let embedder = LatchEmbeddingProvider()
            let memory = try await Memory(at: url) { config in
                config.enableVectorSearch = true
                config.embedding = .custom(embedder)
                config.requireOnDeviceProviders = true
            }
            var configuration = FoundationModelsMemorySessionConfig.default
            configuration.embeddingPolicy = .always
            configuration.persistencePolicy = .none
            configuration.contextStrategy = .promptAugmentation

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: ControllableFoundationModelGenerator()
            )

            let firstPrompt = "prep-a-\(UUID().uuidString)"
            let secondPrompt = "prep-b-\(UUID().uuidString)"
            let firstTask = Task {
                try await session.preparePromptDetailed(for: firstPrompt)
            }
            try await embedder.waitUntilHolding()

            let secondOutcome = TaskOutcome<PreparedMemoryPrompt>()
            let secondTask = Task {
                do {
                    let prepared = try await session.preparePromptDetailed(for: secondPrompt)
                    secondOutcome.set(.success(prepared))
                    return prepared
                } catch {
                    secondOutcome.set(.failure(error))
                    throw error
                }
            }
            try await waitUntilCondition(description: "second prepare queued on generation lease") {
                await session.generationGateWaiterCount() > 0
            }
            #expect(secondOutcome.snapshot() == nil)
            #expect(embedder.peakInFlight() == 1)

            embedder.releaseHold()
            let first = try await withBoundedTimeout(description: "first prepare after latch release") {
                try await firstTask.value
            }
            let second = try await withBoundedTimeout(description: "queued second prepare") {
                try await secondTask.value
            }
            #expect(first.prompt.contains(firstPrompt))
            #expect(second.prompt.contains(secondPrompt))
            #expect(embedder.peakInFlight() == 1)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func waitForGenerationQuiesceTimesOutWhenSessionNeverIdles() async {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        let started = ContinuousClock.now
        let result = await waitForGenerationQuiesce(timeout: .milliseconds(80)) {
            true
        }
        #expect(result == .timedOutStillResponding)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(40))
        #expect(elapsed < .seconds(2))
    }

    @Test
    func waitForGenerationQuiesceDoesNotBusySpinUnderCancel() async {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        let started = ContinuousClock.now
        let task = Task {
            await waitForGenerationQuiesce(timeout: .milliseconds(100)) {
                true
            }
        }
        task.cancel()
        let result = await task.value
        #expect(result == .timedOutStillResponding)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(50))
        #expect(elapsed < .seconds(2))
    }

    @Test
    func waitForGenerationQuiesceReturnsIdledWhenFlagClears() async {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        let flag = NeverIdleThenClearFlag()
        let task = Task {
            await waitForGenerationQuiesce(timeout: .seconds(2)) {
                flag.isResponding
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        flag.isResponding = false
        let result = await task.value
        #expect(result == .idled)
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private final class NeverIdleThenClearFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var responding = true

    var isResponding: Bool {
        get { lock.withLock { responding } }
        set { lock.withLock { responding = newValue } }
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
private final class NestedPrepareHook: @unchecked Sendable {
    private let lock = NSLock()
    private var session: WaxFoundationModelSession?
    private var prepared = false

    var didPrepare: Bool { lock.withLock { prepared } }

    func setSession(_ session: WaxFoundationModelSession) {
        lock.withLock { self.session = session }
    }

    func prepareNested(for prompt: String) async throws {
        let session = lock.withLock { self.session }
        guard let session else { return }
        _ = try await session.preparePromptDetailed(for: prompt)
        lock.withLock { prepared = true }
    }
}

/// Holds the first `embed` until `releaseHold()` so two public prepares can be
/// observed serializing on the generation lease.
private final class LatchEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "test",
        model: "lease-latch",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var remainingHolds = 1
    private var holding = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func peakInFlight() -> Int { lock.withLock { peak } }

    func waitUntilHolding() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if holding {
                lock.unlock()
                continuation.resume()
            } else {
                startedContinuation = continuation
                lock.unlock()
            }
        }
    }

    func releaseHold() {
        let pending: CheckedContinuation<Void, Never>?
        lock.lock()
        pending = releaseContinuation
        releaseContinuation = nil
        holding = false
        lock.unlock()
        pending?.resume()
    }

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        let shouldHold: Bool = lock.withLock {
            inFlight += 1
            peak = max(peak, inFlight)
            let hold = remainingHolds > 0
            if hold { remainingHolds -= 1 }
            return hold
        }
        defer { lock.withLock { inFlight -= 1 } }
        guard shouldHold else {
            return [1, 0, 0, 0]
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            holding = true
            let started = startedContinuation
            startedContinuation = nil
            releaseContinuation = continuation
            lock.unlock()
            started?.resume()
        }
        return [1, 0, 0, 0]
    }
}
#endif
