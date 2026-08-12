#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WaxCore

/// Package-internal generation backend for ``WaxFoundationModelSession``.
///
/// Production uses ``LiveLanguageModelGenerator`` (Apple's ``LanguageModelSession``).
/// Tests inject a controllable fake so concurrency and cancellation can be asserted
/// without the live on-device model. Task 8 should keep this seam when introducing
/// ``WaxFoundationModelStream``.
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
}

/// Thin stream that forwards text snapshots. Task 7 holds the session generation
/// lease until this stream finishes, fails, or is cancelled. Task 8 replaces it
/// with ``WaxFoundationModelStream`` (events + persistence lifecycle).
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxGenerationLeaseStream: AsyncSequence, Sendable {
    public typealias Element = String
    public typealias Failure = Error

    private let stream: AsyncThrowingStream<String, Error>

    package init(stream: AsyncThrowingStream<String, Error>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<String, Error>.Iterator {
        stream.makeAsyncIterator()
    }

    public func collect() async throws -> String {
        var last = ""
        for try await chunk in stream {
            last = chunk
        }
        return last
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
package struct LiveLanguageModelGenerator: WaxFoundationModelGenerating {
    let session: LanguageModelSession

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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let appleStream = session.streamResponse(to: prompt, options: options)
                    for try await snapshot in appleStream {
                        continuation.yield(Self.stringifyPartial(snapshot.content))
                    }
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

    private static func stringifyPartial<T>(_ value: T) -> String {
        if let string = value as? String {
            return string
        }
        return String(describing: value)
    }
}

/// Releases an ``AsyncMutex`` at most once. Used so stream `onTermination` and the
/// producer `defer` cannot double-unlock the generation gate.
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

    package func release() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        guard shouldRelease else { return }
        Task {
            await gate.unlock()
        }
    }
}
#endif
