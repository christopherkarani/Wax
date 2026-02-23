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
