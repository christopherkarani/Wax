import Foundation
import Testing
@testable import WaxCore

// MARK: - ReadWriteLock Tests (synchronous, platform lock based)

@Test func readWriteLockWithReadLockReturnsValue() {
    let lock = ReadWriteLock()
    let result = lock.withReadLock { 42 }
    #expect(result == 42)
}

@Test func readWriteLockWithWriteLockReturnsValue() {
    let lock = ReadWriteLock()
    let result = lock.withWriteLock { "hello" }
    #expect(result == "hello")
}

@Test func readWriteLockMultipleConcurrentReaders() {
    let lock = ReadWriteLock()
    let sharedValue = 100
    let iterations = 1000
    let concurrency = 8

    // Use a lock-protected counter to verify all reads complete successfully
    let resultLock = UnfairLock()
    nonisolated(unsafe) var successCount = 0

    DispatchQueue.concurrentPerform(iterations: concurrency) { _ in
        for _ in 0..<iterations {
            let value = lock.withReadLock { sharedValue }
            if value == sharedValue {
                resultLock.withLock { successCount += 1 }
            }
        }
    }

    #expect(successCount == concurrency * iterations)
}

@Test func readWriteLockWriterExclusivity() {
    let lock = ReadWriteLock()
    nonisolated(unsafe) var counter = 0
    let iterations = 1000
    let concurrency = 8

    DispatchQueue.concurrentPerform(iterations: concurrency) { _ in
        for _ in 0..<iterations {
            lock.withWriteLock {
                // Read-modify-write must be atomic under write lock
                let current = counter
                counter = current + 1
            }
        }
    }

    // If writer exclusivity holds, counter == concurrency * iterations
    #expect(counter == concurrency * iterations)
}

// MARK: - AsyncReadWriteLock Tests

@Test func asyncReadWriteLockBasicRead() async {
    let lock = AsyncReadWriteLock()
    let result = await lock.withReadLock { 99 }
    #expect(result == 99)
}

@Test func asyncReadWriteLockBasicWrite() async {
    let lock = AsyncReadWriteLock()
    let result = await lock.withWriteLock { "written" }
    #expect(result == "written")
}

@Test func asyncReadWriteLockConcurrentReads() async {
    let lock = AsyncReadWriteLock()
    let expected = 42

    // Launch multiple concurrent readers; all should succeed
    await withTaskGroup(of: Int.self) { group in
        for _ in 0..<10 {
            group.addTask {
                await lock.withReadLock { expected }
            }
        }
        for await value in group {
            #expect(value == expected)
        }
    }
}

@Test func asyncReadWriteLockWriterExclusiveAccess() async {
    let lock = AsyncReadWriteLock()
    // Use an actor to safely accumulate results
    actor Counter {
        var value = 0
        func increment() { value += 1 }
        func get() -> Int { value }
    }
    let counter = Counter()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 {
            group.addTask {
                await lock.withWriteLock {
                    let current = await counter.get()
                    await counter.increment()
                    _ = current
                }
            }
        }
    }

    let finalValue = await counter.get()
    #expect(finalValue == 100)
}

@Test func asyncReadWriteLockWriterBlocksReaders() async {
    let lock = AsyncReadWriteLock()

    actor Timeline {
        var events: [String] = []
        func append(_ event: String) { events.append(event) }
        func get() -> [String] { events }
    }
    let timeline = Timeline()

    // Acquire write lock first
    await lock.writeLock()

    // Start a reader task that will be blocked
    let readerTask = Task {
        await lock.withReadLock {
            await timeline.append("read")
        }
    }

    // Give the reader task time to enqueue
    try? await Task.sleep(for: .milliseconds(50))

    // Record that write is finishing, then release
    await timeline.append("write-done")
    await lock.writeUnlock()

    // Wait for reader to complete
    await readerTask.value

    let events = await timeline.get()
    // Writer must finish before reader starts
    #expect(events == ["write-done", "read"])
}

@Test func asyncReadWriteLockWriterPreference() async {
    let lock = AsyncReadWriteLock()

    actor Timeline {
        var events: [String] = []
        func append(_ event: String) { events.append(event) }
        func get() -> [String] { events }
    }
    let timeline = Timeline()

    // Start with a reader holding the lock
    await lock.readLock()

    // Queue a writer (will wait for reader to finish)
    let writerTask = Task {
        await lock.withWriteLock {
            await timeline.append("writer")
        }
    }

    // Give writer time to enqueue
    try? await Task.sleep(for: .milliseconds(50))

    // Queue a new reader (should wait for the pending writer per writer-preference)
    let readerTask = Task {
        await lock.withReadLock {
            await timeline.append("reader")
        }
    }

    // Give reader time to enqueue
    try? await Task.sleep(for: .milliseconds(50))

    // Release the initial read lock, which should wake the writer first
    await lock.readUnlock()

    await writerTask.value
    await readerTask.value

    let events = await timeline.get()
    // Writer-preference: pending writer is served before new reader
    #expect(events == ["writer", "reader"])
}

@Test func asyncReadWriteLockReadErrorPropagation() async {
    let lock = AsyncReadWriteLock()

    struct TestError: Error, Equatable {}

    await #expect(throws: TestError.self) {
        try await lock.withReadLock {
            throw TestError()
        }
    }
}

@Test func asyncReadWriteLockWriteErrorPropagation() async {
    let lock = AsyncReadWriteLock()

    struct TestError: Error, Equatable {}

    await #expect(throws: TestError.self) {
        try await lock.withWriteLock {
            throw TestError()
        }
    }
}

// MARK: - UnfairLock Tests

@Test func unfairLockWithLockWorks() {
    let lock = UnfairLock()
    nonisolated(unsafe) var counter = 0
    let iterations = 1000
    let concurrency = 8

    DispatchQueue.concurrentPerform(iterations: concurrency) { _ in
        for _ in 0..<iterations {
            lock.withLock {
                counter += 1
            }
        }
    }

    #expect(counter == concurrency * iterations)
}

@Test func unfairLockTryAcquire() {
    let lock = UnfairLock()

    // Lock is free, tryAcquire should succeed
    let acquired = lock.tryAcquire()
    #expect(acquired == true)

    // Lock is held, tryAcquire should fail
    let acquiredAgain = lock.tryAcquire()
    #expect(acquiredAgain == false)

    // Release and try again
    lock.release()
    let acquiredAfterRelease = lock.tryAcquire()
    #expect(acquiredAfterRelease == true)
    lock.release()
}
