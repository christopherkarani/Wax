#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WaxCore

/// Owning Foundation Models stream. Holds the session generation lease until the
/// sequence finishes, fails, is cancelled, or is dropped. A user turn is persisted
/// only after the first ``Event/content``; assistant text is persisted only on
/// normal completion.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct WaxGenerationStream: AsyncSequence, Sendable {
    public enum Event: Sendable, Equatable {
        case content(String)
        case completed(WaxFMResponse<String>)
    }

    public typealias Element = Event
    public typealias Failure = Error

    private let stream: AsyncThrowingStream<Event, Error>
    private let lifetime: Lifetime

    package init(
        stream: AsyncThrowingStream<Event, Error>,
        cancelProducer: @escaping @Sendable () -> Void
    ) {
        self.stream = stream
        self.lifetime = Lifetime(cancel: cancelProducer)
    }

    public func makeAsyncIterator() -> Iterator {
        if lifetime.claimIterator() {
            return Iterator(
                inner: stream.makeAsyncIterator(),
                lifetime: lifetime,
                invalidated: false
            )
        }
        return Iterator(inner: nil, lifetime: nil, invalidated: true)
    }

    /// Consumes the stream to the terminal ``Event/completed`` event.
    public func collect() async throws -> WaxFMResponse<String> {
        var completed: WaxFMResponse<String>?
        for try await event in self {
            if case .completed(let response) = event {
                completed = response
            }
        }
        guard let completed else {
            throw WaxError.invalidConfiguration(
                reason: "WaxGenerationStream ended without a completed event"
            )
        }
        return completed
    }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Event

        private var inner: AsyncThrowingStream<Event, Error>.Iterator?
        private let lifetime: Lifetime?
        private let invalidated: Bool

        fileprivate init(
            inner: AsyncThrowingStream<Event, Error>.Iterator?,
            lifetime: Lifetime?,
            invalidated: Bool
        ) {
            self.inner = inner
            self.lifetime = lifetime
            self.invalidated = invalidated
        }

        public mutating func next() async throws -> Event? {
            if invalidated {
                throw WaxError.invalidConfiguration(
                    reason: "WaxGenerationStream supports a single iterator"
                )
            }
            // Retain `lifetime` for the pull so dropping other stream copies
            // cannot cancel the producer while this iterator is in flight.
            _ = lifetime
            return try await inner?.next()
        }
    }

    /// Cancels the producer when the last stream/iterator handle is dropped, and
    /// allows only one iterator to pull events.
    fileprivate final class Lifetime: @unchecked Sendable {
        private let cancel: @Sendable () -> Void
        private let lock = NSLock()
        private var iteratorClaimed = false
        private var didCancel = false

        init(cancel: @escaping @Sendable () -> Void) {
            self.cancel = cancel
        }

        func claimIterator() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if iteratorClaimed { return false }
            iteratorClaimed = true
            return true
        }

        func cancelOnce() {
            lock.lock()
            let shouldCancel = !didCancel
            didCancel = true
            lock.unlock()
            guard shouldCancel else { return }
            cancel()
        }

        deinit {
            cancelOnce()
        }
    }
}
#endif
