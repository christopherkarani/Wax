#if canImport(FoundationModels)
import Foundation
import FoundationModels
@testable import Wax

struct FoundationModelGeneratorWaitTimeout: Error, CustomStringConvertible {
    let reason: String
    var description: String { "timed out waiting for \(reason)" }

    init(_ reason: String) {
        self.reason = reason
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
final class ControllableFoundationModelGenerator: WaxFoundationModelGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private let blockUntilCancelled: Bool
    private var remainingPersistenceHolds: Int
    private var inFlight = 0
    private var peakInFlight = 0
    private var completed: [String] = []
    private var generateCalls = 0
    private var observedCancellation = false
    private var holdingBeforePersistence = false
    private var persistenceHoldContinuation: CheckedContinuation<Void, Never>?

    init(
        delay: Duration = .milliseconds(20),
        blockUntilCancelled: Bool = false,
        pauseBeforePersistence: Bool = false
    ) {
        self.delay = delay
        self.blockUntilCancelled = blockUntilCancelled
        self.remainingPersistenceHolds = pauseBeforePersistence ? 1 : 0
    }

    func maxInFlight() -> Int {
        lock.withLock { peakInFlight }
    }

    func completedPrompts() -> [String] {
        lock.withLock { completed }
    }

    func generateCallCount() -> Int {
        lock.withLock { generateCalls }
    }

    func didObserveCancellation() -> Bool {
        lock.withLock { observedCancellation }
    }

    func isGenerating() -> Bool {
        lock.withLock { inFlight > 0 }
    }

    func isHoldingBeforePersistence() -> Bool {
        lock.withLock { holdingBeforePersistence }
    }

    func waitUntilGenerating(timeout: Duration = .seconds(5)) async throws {
        try await pollFlag(timeout: timeout, description: "isGenerating") { isGenerating() }
    }

    func waitUntilPersistenceHold(timeout: Duration = .seconds(5)) async throws {
        try await pollFlag(timeout: timeout, description: "persistence hold") {
            isHoldingBeforePersistence()
        }
    }

    func generateText(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        _ = options
        let shouldBlockUntilCancelled: Bool = lock.withLock {
            generateCalls += 1
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            // Only the in-flight stream/respond under test parks; a follow-up
            // `respond` after lease release must complete normally.
            return blockUntilCancelled && generateCalls == 1
        }
        defer {
            lock.withLock { inFlight -= 1 }
        }

        if shouldBlockUntilCancelled {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(15))
                }
            } catch is CancellationError {
                lock.withLock { observedCancellation = true }
                throw CancellationError()
            }
            lock.withLock { observedCancellation = true }
            throw CancellationError()
        }

        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        lock.withLock { completed.append(prompt) }
        return "reply:\(prompt)"
    }

    func generateStructured<T: Generable>(
        prompt: String,
        type: T.Type,
        options: GenerationOptions
    ) async throws -> T {
        _ = try await generateText(prompt: prompt, options: options)
        throw CancellationError()
    }

    func streamText(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Yield a prefix before the underlying generate so tests can
                    // consume a chunk, then cancel while generation is still open.
                    continuation.yield("partial:\(prompt)")
                    let text = try await self.generateText(prompt: prompt, options: options)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func holdBeforePersistence() async throws {
        let shouldHold = lock.withLock {
            guard remainingPersistenceHolds > 0 else { return false }
            remainingPersistenceHolds -= 1
            return true
        }
        guard shouldHold else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.holdingBeforePersistence = true
                    self.lock.unlock()
                    continuation.resume()
                    return
                }
                self.holdingBeforePersistence = true
                self.persistenceHoldContinuation = continuation
                self.lock.unlock()
            }
        } onCancel: {
            self.resumePersistenceHold()
        }
        lock.withLock { holdingBeforePersistence = false }
    }

    private func resumePersistenceHold() {
        let pending: CheckedContinuation<Void, Never>?
        lock.lock()
        pending = persistenceHoldContinuation
        persistenceHoldContinuation = nil
        lock.unlock()
        pending?.resume()
    }

    private func pollFlag(
        timeout: Duration,
        description: String,
        isMet: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if isMet() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        if isMet() { return }
        throw FoundationModelGeneratorWaitTimeout(description)
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
func withBoundedTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(5),
    description: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FoundationModelGeneratorWaitTimeout(description)
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
#endif
