#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WaxCore

/// Package-internal generation backend for ``WaxFoundationModelSession``.
///
/// Production uses ``LiveLanguageModelGenerator`` (Apple's ``LanguageModelSession``).
/// Tests inject a controllable fake so concurrency and cancellation can be asserted
/// without the live on-device model. Streaming lifecycle and persistence live on
/// ``WaxGenerationStream``.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package protocol WaxFoundationModelGenerating: Sendable {
    func generateText(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String

    func generateStructured<T: Generable>(
        prompt: String,
        type: T.Type,
        options: GenerationOptions
    ) async throws -> T

    func streamText(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>

    /// Waits until the backing stream request has fully terminated, including Apple
    /// ``LanguageModelSession`` teardown after cancel/drop. Production generators
    /// join the unstructured Apple consumer; test fakes join their linger task.
    func joinStream() async

    /// Test seam invoked after generation succeeds and immediately before turn persistence.
    /// Production generators no-op; the controllable fake can park here so tests cancel
    /// in the post-generation persistence window.
    func holdBeforePersistence() async throws
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension WaxFoundationModelGenerating {
    package func holdBeforePersistence() async throws {}
    package func joinStream() async {}
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package struct LiveLanguageModelGenerator: WaxFoundationModelGenerating {
    let session: LanguageModelSession
    private let streamJoin = StreamJoinBox()

    package init(session: LanguageModelSession) {
        self.session = session
    }

    package func generateText(
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        try await session.respond(to: prompt, options: options).content
    }

    package func generateStructured<T: Generable>(
        prompt: String,
        type: T.Type,
        options: GenerationOptions
    ) async throws -> T {
        try await session.respond(to: prompt, generating: type, options: options).content
    }

    package func streamText(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let join = streamJoin
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let appleStream = session.streamResponse(to: prompt, options: options)
                    for try await snapshot in appleStream {
                        continuation.yield(Self.stringifyPartial(snapshot.content))
                    }
                    await Self.waitUntilSessionQuiesced(session)
                    continuation.finish()
                } catch {
                    await Self.waitUntilSessionQuiesced(session)
                    continuation.finish(throwing: error)
                }
            }
            join.attach(task)
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package func joinStream() async {
        await streamJoin.join()
    }

    private static func stringifyPartial<T>(_ value: T) -> String {
        if let string = value as? String {
            return string
        }
        return String(describing: value)
    }

    /// Cancellation of the Swift consumer is not Apple idle. Keep waiting even if
    /// this task is cancelled so the generation lease cannot be released while
    /// ``LanguageModelSession/isResponding`` is still true.
    ///
    /// Uses uncooperative backoff so a cancelled consumer does not busy-spin.
    /// A slice timeout does **not** release the lease: we keep waiting until idle.
    private static func waitUntilSessionQuiesced(_ session: LanguageModelSession) async {
        while session.isResponding {
            switch await waitForGenerationQuiesce(
                timeout: .seconds(30),
                isResponding: { session.isResponding }
            ) {
            case .idled:
                return
            case .timedOutStillResponding:
                continue
            }
        }
    }
}

/// Outcome of a bounded Apple-idle wait. ``timedOutStillResponding`` is fail-safe:
/// callers must keep the generation lease and keep waiting.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package enum GenerationQuiesceResult: Sendable, Equatable {
    case idled
    case timedOutStillResponding
}

/// Waits until `isResponding` is false, or `timeout` elapses. Sleeps on a detached
/// task so caller cancellation cannot turn the wait into a busy `yield` loop.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package func waitForGenerationQuiesce(
    timeout: Duration,
    initialBackoffMilliseconds: Int = 2,
    maxBackoffMilliseconds: Int = 50,
    isResponding: () -> Bool
) async -> GenerationQuiesceResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var delayMs = max(1, initialBackoffMilliseconds)
    let maxDelayMs = max(delayMs, maxBackoffMilliseconds)
    while isResponding() {
        if clock.now >= deadline {
            return .timedOutStillResponding
        }
        await sleepUncooperatively(.milliseconds(delayMs))
        delayMs = min(delayMs * 2, maxDelayMs)
    }
    return .idled
}

/// Sleep that does not observe the caller's cancellation flag.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package func sleepUncooperatively(_ duration: Duration) async {
    guard duration > .zero else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Task.detached {
            try? await Task.sleep(for: duration)
            continuation.resume()
        }
    }
}

/// Tracks the unstructured Apple stream consumer so lease release can join it.
private final class StreamJoinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func attach(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func join() async {
        let task = lock.withLock { self.task }
        await task?.value
    }
}

/// Holds a replaceable ``LanguageModelSession`` so context-overflow retry can
/// install a fresh transcript without changing the public nonisolated handle type.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package final class LanguageModelSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: LanguageModelSession

    package init(_ session: LanguageModelSession) {
        self._session = session
    }

    package var session: LanguageModelSession {
        lock.withLock { _session }
    }

    package func replace(_ session: LanguageModelSession) {
        lock.withLock { _session = session }
    }
}
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package final class GenerationLease: @unchecked Sendable {
    private let gate: AsyncMutex
    private let lock = NSLock()
    private var released = false

    package init(gate: AsyncMutex) {
        self.gate = gate
    }

    package func release() async {
        let shouldRelease = lock.withLock { () -> Bool in
            let shouldRelease = !released
            released = true
            return shouldRelease
        }
        guard shouldRelease else { return }
        await gate.unlock()
    }
}
#endif
