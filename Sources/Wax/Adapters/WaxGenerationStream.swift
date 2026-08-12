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
                puller: EventPuller(
                    inner: stream.makeAsyncIterator(),
                    lifetime: lifetime,
                    invalidated: false
                )
            )
        }
        return Iterator(
            puller: EventPuller(inner: nil, lifetime: nil, invalidated: true)
        )
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
            throw WaxFoundationModelsError.invalidConfiguration(
                "WaxGenerationStream ended without a completed event"
            )
        }
        return completed
    }

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Event

        fileprivate let puller: EventPuller

        public mutating func next() async throws -> Event? {
            try await puller.next()
        }
    }

    /// Forwards producer events through a mailbox so cancelling the consuming
    /// task still surfaces the producer's mapped terminal error
    /// (``WaxFoundationModelsError/cancelled(didPersistUser:didPersistAssistant:)``)
    /// instead of raw `CancellationError` or a nil finish.
    fileprivate final class EventPuller: @unchecked Sendable {
        private let lifetime: Lifetime?
        private let invalidated: Bool
        private let mailbox = Mailbox()

        init(
            inner: AsyncThrowingStream<Event, Error>.Iterator?,
            lifetime: Lifetime?,
            invalidated: Bool
        ) {
            self.lifetime = lifetime
            self.invalidated = invalidated
            if invalidated { return }
            let mailbox = self.mailbox
            if let inner {
                let pump = InnerPump(iterator: inner, mailbox: mailbox)
                Task.detached {
                    await pump.run()
                }
            }
        }

        func next() async throws -> Event? {
            if invalidated {
                throw WaxFoundationModelsError.iteratorAlreadyCreated
            }
            // Retain `lifetime` for the pull so dropping other stream copies
            // cannot cancel the producer while this iterator is in flight.
            _ = lifetime
            let result = await withTaskCancellationHandler {
                await self.mailbox.pop()
            } onCancel: {
                self.lifetime?.cancelOnce()
            }
            return try result.get()
        }
    }

    fileprivate final class InnerPump: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Event, Error>.Iterator
        private let mailbox: Mailbox

        init(
            iterator: AsyncThrowingStream<Event, Error>.Iterator,
            mailbox: Mailbox
        ) {
            self.iterator = iterator
            self.mailbox = mailbox
        }

        func run() async {
            do {
                while let event = try await iterator.next() {
                    mailbox.push(.success(event))
                }
                mailbox.push(.success(nil))
            } catch {
                mailbox.push(.failure(error))
            }
        }
    }
    fileprivate final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [Result<Event?, Error>] = []
        private var waiter: UnsafeContinuation<Result<Event?, Error>, Never>?

        func push(_ result: Result<Event?, Error>) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: result)
                return
            }
            buffer.append(result)
            lock.unlock()
        }

        func pop() async -> Result<Event?, Error> {
            await withUnsafeContinuation { continuation in
                lock.lock()
                if !buffer.isEmpty {
                    let value = buffer.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
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
