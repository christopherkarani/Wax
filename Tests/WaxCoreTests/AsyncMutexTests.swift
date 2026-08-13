import Foundation
import Testing
@testable import WaxCore

@Test func asyncMutexBasicLockUnlock() async throws {
    let mutex = AsyncMutex()
    try await mutex.lock()
    await mutex.unlock()
}

@Test func asyncMutexWithLockExecutesBody() async throws {
    let mutex = AsyncMutex()
    let result = try await mutex.withLock { 42 }
    #expect(result == 42)
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

@Test func asyncMutexSerializesAccess() async throws {
    let mutex = AsyncMutex()
    let counter = MutexTestCounter()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                try await mutex.withLock {
                    let current = await counter.value
                    await Task.yield()
                    await counter.set(current + 1)
                }
            }
        }
        try await group.waitForAll()
    }

    let final = await counter.value
    #expect(final == 10)
}

@Test func asyncMutexRemovesCancelledWaitersFromFIFO() async throws {
    let mutex = AsyncMutex()
    try await mutex.lock()

    let waiter = Task {
        try await mutex.lock()
    }
    try await waitUntilMutex(description: "cancelled-waiter parked") {
        await mutex.waiterCount == 1
    }

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
        try await waiter.value
    }
    #expect(await mutex.waiterCount == 0)

    let next = Task {
        try await mutex.lock()
    }
    try await waitUntilMutex(description: "successor parked behind holder") {
        await mutex.waiterCount == 1
    }
    await mutex.unlock()
    try await next.value
    #expect(await mutex.waiterCount == 0)
    await mutex.unlock()
}

@Test func asyncMutexCancelledLockDoesNotAcquireWhenFree() async throws {
    let mutex = AsyncMutex()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await mutex.lock()
    }
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    try await mutex.lock()
    await mutex.unlock()
}

private actor MutexTestCounter {
    var value: Int = 0
    func set(_ v: Int) { value = v }
}

private struct MutexWaitTimeout: Error {
    let description: String
}

private func waitUntilMutex(
    timeout: Duration = .seconds(2),
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
    throw MutexWaitTimeout(description: description)
}
