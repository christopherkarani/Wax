import Foundation
import Testing
@testable import WaxCore

@Test func asyncMutexBasicLockUnlock() async {
    let mutex = AsyncMutex()
    await mutex.lock()
    await mutex.unlock()
}

@Test func asyncMutexWithLockExecutesBody() async throws {
    let mutex = AsyncMutex()
    let result = await mutex.withLock { 42 }
    #expect(result == 42)
}

@Test(.timeLimit(.minutes(1)))
func asyncMutexWaitUntilWaitingResumesOnceATaskIsParked() async {
    let mutex = AsyncMutex()
    await mutex.lock()

    let contender = Task {
        await mutex.withLock { 7 }
    }
    // Event-driven: resumes when the contender parks in lock(), with no poll.
    await mutex.waitUntilWaiting(atLeast: 1)
    #expect(await mutex.waiterCount == 1)

    await mutex.unlock()
    #expect(await contender.value == 7)
    #expect(await mutex.waiterCount == 0)
}

@Test func asyncMutexWaitUntilWaitingReturnsWhenAlreadySatisfied() async {
    let mutex = AsyncMutex()
    await mutex.waitUntilWaiting(atLeast: 0)
}

/// A cancelled observer must return instead of hanging, so a `.timeLimit` can
/// end a test whose expected waiter never parks.
@Test(.timeLimit(.minutes(1)))
func asyncMutexWaitUntilWaitingReturnsWhenCancelled() async {
    let mutex = AsyncMutex()
    let observer = Task {
        await mutex.waitUntilWaiting(atLeast: 1)
    }
    observer.cancel()
    await observer.value

    // The cancelled observer is gone; a later parked waiter still resolves a new one.
    await mutex.lock()
    let contender = Task { await mutex.withLock { 1 } }
    await mutex.waitUntilWaiting(atLeast: 1)
    await mutex.unlock()
    #expect(await contender.value == 1)
}

@Test func asyncMutexWithLockThrowingBody() async {
    let mutex = AsyncMutex()
    do {
        _ = try await mutex.withLock {
            throw WaxError.io("test")
        }
        Issue.record("Expected error")
    } catch {
        // Expected
    }
}

@Test func asyncMutexSerializesAccess() async {
    let mutex = AsyncMutex()
    let counter = MutexTestCounter()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                await mutex.withLock {
                    let current = await counter.value
                    // Yield to provoke interleaving
                    await Task.yield()
                    await counter.set(current + 1)
                }
            }
        }
    }

    let final = await counter.value
    #expect(final == 10)
}

private actor MutexTestCounter {
    var value: Int = 0
    func set(_ v: Int) { value = v }
}
