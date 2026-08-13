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

struct ControllableFoundationModelGuardrailError: Error, Equatable {}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable
struct FoundationModelTestReply: Equatable, Sendable {
    var text: String

    init(text: String) {
        self.text = text
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
final class ControllableFoundationModelGenerator: WaxFoundationModelGenerating, @unchecked Sendable {
    enum StreamFailurePoint: Sendable {
        case none
        case beforeFirstChunk
        case afterFirstChunk
    }

    private let lock = NSLock()
    private let delay: Duration
    private let blockUntilCancelled: Bool
    private let streamFailure: StreamFailurePoint
    private let generateError: Error?
    private var remainingGenerateErrors: Int
    private let streamError: Error?
    private var remainingStreamErrors: Int
    private var remainingPersistenceHolds: Int
    private var remainingFirstChunkHolds: Int
    private var inFlight = 0
    private var peakInFlight = 0
    private var completed: [String] = []
    private var generateCalls = 0
    private var streamCalls = 0
    private var observedCancellation = false
    private var holdingBeforePersistence = false
    private var persistenceHoldContinuation: CheckedContinuation<Void, Never>?
    private var holdingBeforeFirstChunk = false
    private var firstChunkHoldContinuation: CheckedContinuation<Void, Never>?
    private var forceCancel = false
    private let structuredResult: (any Sendable)?
    private let lingerAfterCancel: Bool
    private var underlyingRequests = 0
    private var lingeringAfterCancel = false
    private var lingerReleased = false
    private var lingerContinuation: CheckedContinuation<Void, Never>?
    private var streamTask: Task<Void, Never>?
    /// Invoked while a generate call is in-flight (lease held). Simulates a
    /// Foundation Models tool that re-enters the session.
    private let onGenerate: (@Sendable () async throws -> Void)?

    init(
        delay: Duration = .milliseconds(20),
        blockUntilCancelled: Bool = false,
        pauseBeforePersistence: Bool = false,
        pauseBeforeFirstChunk: Bool = false,
        lingerAfterCancel: Bool = false,
        streamFailure: StreamFailurePoint = .none,
        generateError: Error? = nil,
        generateErrorCount: Int = 1,
        streamError: Error? = nil,
        streamErrorCount: Int = 1,
        structuredResult: (any Sendable)? = nil,
        onGenerate: (@Sendable () async throws -> Void)? = nil
    ) {
        self.delay = delay
        self.blockUntilCancelled = blockUntilCancelled
        self.streamFailure = streamFailure
        self.generateError = generateError
        self.remainingGenerateErrors = generateError == nil ? 0 : max(0, generateErrorCount)
        self.streamError = streamError
        self.remainingStreamErrors = streamError == nil ? 0 : max(0, streamErrorCount)
        self.remainingPersistenceHolds = pauseBeforePersistence ? 1 : 0
        self.remainingFirstChunkHolds = pauseBeforeFirstChunk ? 1 : 0
        self.structuredResult = structuredResult
        self.lingerAfterCancel = lingerAfterCancel
        self.onGenerate = onGenerate
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

    func streamCallCount() -> Int {
        lock.withLock { streamCalls }
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

    func isHoldingBeforeFirstChunk() -> Bool {
        lock.withLock { holdingBeforeFirstChunk }
    }

    func isUnderlyingRequestActive() -> Bool {
        lock.withLock { underlyingRequests > 0 }
    }

    func isLingeringAfterCancel() -> Bool {
        lock.withLock { lingeringAfterCancel }
    }

    func requestCancellation() {
        lock.withLock { forceCancel = true }
    }

    func releaseLingerAfterCancel() {
        let pending: CheckedContinuation<Void, Never>?
        lock.lock()
        lingerReleased = true
        pending = lingerContinuation
        lingerContinuation = nil
        lock.unlock()
        pending?.resume()
    }

    func waitUntilLingeringAfterCancel(timeout: Duration = .seconds(60)) async throws {
        try await pollFlag(timeout: timeout, description: "linger after cancel") {
            isLingeringAfterCancel()
        }
    }

    func waitUntilUnderlyingRequestActive(timeout: Duration = .seconds(60)) async throws {
        try await pollFlag(timeout: timeout, description: "underlying request active") {
            isUnderlyingRequestActive()
        }
    }

    func joinStream() async {
        let task = lock.withLock { streamTask }
        await task?.value
    }

    func waitUntilGenerating(timeout: Duration = .seconds(60)) async throws {
        try await pollFlag(timeout: timeout, description: "isGenerating") { isGenerating() }
    }

    func waitUntilPersistenceHold(timeout: Duration = .seconds(60)) async throws {
        try await pollFlag(timeout: timeout, description: "persistence hold") {
            isHoldingBeforePersistence()
        }
    }

    func waitUntilHoldingBeforeFirstChunk(timeout: Duration = .seconds(60)) async throws {
        try await pollFlag(timeout: timeout, description: "first-chunk hold") {
            isHoldingBeforeFirstChunk()
        }
    }

    func generateText(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        _ = options
        let planned: (shouldBlockUntilCancelled: Bool, error: Error?) = lock.withLock {
            generateCalls += 1
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            let error: Error?
            if remainingGenerateErrors > 0, let generateError {
                remainingGenerateErrors -= 1
                error = generateError
            } else {
                error = nil
            }
            return (blockUntilCancelled && generateCalls == 1 && error == nil, error)
        }
        defer {
            lock.withLock { inFlight -= 1 }
        }
        if let error = planned.error {
            throw error
        }
        let shouldBlockUntilCancelled = planned.shouldBlockUntilCancelled

        if shouldBlockUntilCancelled {
            do {
                while !Task.isCancelled && !lock.withLock({ forceCancel }) {
                    try await Task.sleep(for: .milliseconds(15))
                }
            } catch is CancellationError {
                lock.withLock { observedCancellation = true }
                throw CancellationError()
            }
            lock.withLock { observedCancellation = true }
            throw CancellationError()
        }

        if let onGenerate {
            try await onGenerate()
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
        _ = type
        _ = try await generateText(prompt: prompt, options: options)
        if let structuredResult, let value = structuredResult as? T {
            return value
        }
        throw ControllableFoundationModelGuardrailError()
    }

    func streamText(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                self.lock.withLock {
                    self.streamCalls += 1
                    self.underlyingRequests += 1
                }
                defer {
                    self.lock.withLock { self.underlyingRequests -= 1 }
                }
                do {
                    try await self.holdBeforeFirstChunkIfNeeded()
                    try Task.checkCancellation()
                    let plannedStreamError: Error? = self.lock.withLock {
                        if remainingStreamErrors > 0, let streamError {
                            remainingStreamErrors -= 1
                            return streamError
                        }
                        return nil
                    }
                    if let plannedStreamError {
                        throw plannedStreamError
                    }
                    if self.streamFailure == .beforeFirstChunk {
                        throw ControllableFoundationModelGuardrailError()
                    }
                    // Yield a prefix before the underlying generate so tests can
                    // consume a chunk, then cancel while generation is still open.
                    continuation.yield("partial:\(prompt)")
                    if self.streamFailure == .afterFirstChunk {
                        throw ControllableFoundationModelGuardrailError()
                    }
                    let text = try await self.generateText(prompt: prompt, options: options)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                    await self.lingerAfterCancelIfNeeded()
                }
            }
            self.lock.withLock { self.streamTask = task }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func lingerAfterCancelIfNeeded() async {
        guard lingerAfterCancel else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if lingerReleased {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.lingeringAfterCancel = true
            self.lingerContinuation = continuation
            self.lock.unlock()
        }
        lock.withLock { lingeringAfterCancel = false }
    }

    private func holdBeforeFirstChunkIfNeeded() async throws {
        let shouldHold = lock.withLock {
            guard remainingFirstChunkHolds > 0 else { return false }
            remainingFirstChunkHolds -= 1
            return true
        }
        guard shouldHold else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.holdingBeforeFirstChunk = true
                    self.lock.unlock()
                    continuation.resume()
                    return
                }
                self.holdingBeforeFirstChunk = true
                self.firstChunkHoldContinuation = continuation
                self.lock.unlock()
            }
        } onCancel: {
            self.resumeFirstChunkHold()
        }
        lock.withLock { holdingBeforeFirstChunk = false }
        try Task.checkCancellation()
    }

    private func resumeFirstChunkHold() {
        let pending: CheckedContinuation<Void, Never>?
        lock.lock()
        pending = firstChunkHoldContinuation
        firstChunkHoldContinuation = nil
        lock.unlock()
        pending?.resume()
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
    _ timeout: Duration = .seconds(30),
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

func waitUntilCondition(
    timeout: Duration = .seconds(30),
    description: String,
    isMet: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await isMet() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    if await isMet() { return }
    throw FoundationModelGeneratorWaitTimeout(description)
}

final class TaskOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func snapshot() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
#endif
