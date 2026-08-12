#if canImport(FoundationModels)
import Foundation
import FoundationModels
@testable import Wax

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
final class ControllableFoundationModelGenerator: WaxFoundationModelGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private let blockUntilCancelled: Bool
    private var inFlight = 0
    private var peakInFlight = 0
    private var completed: [String] = []
    private var generateCalls = 0
    private var observedCancellation = false

    init(delay: Duration = .milliseconds(20), blockUntilCancelled: Bool = false) {
        self.delay = delay
        self.blockUntilCancelled = blockUntilCancelled
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

    func generateText(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        _ = options
        lock.withLock {
            generateCalls += 1
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
        }
        defer {
            lock.withLock { inFlight -= 1 }
        }

        if blockUntilCancelled {
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
}
#endif
