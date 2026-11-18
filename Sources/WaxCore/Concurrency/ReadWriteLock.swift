import Foundation

/// Async-compatible ReadWriteLock using continuations.
package actor AsyncReadWriteLock {
    private var readers: Int = 0
    private var writers: Int = 0
    private var writerWaiters: [CheckedContinuation<Void, Never>] = []
    private var readerWaiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func readLock() async {
        if writers > 0 || !writerWaiters.isEmpty {
            await withCheckedContinuation { continuation in
                readerWaiters.append(continuation)
            }
        } else {
            readers += 1
        }
    }

    package func readUnlock() {
        if readers > 0 {
            readers -= 1
        }
        if readers == 0 && !writerWaiters.isEmpty {
            let nextWriter = writerWaiters.removeFirst()
            writers += 1
            nextWriter.resume()
        }
    }

    package func writeLock() async {
        if readers > 0 || writers > 0 {
            await withCheckedContinuation { continuation in
                writerWaiters.append(continuation)
            }
        } else {
            writers += 1
        }
    }

    package func writeUnlock() {
        writers -= 1
        if !writerWaiters.isEmpty {
            let nextWriter = writerWaiters.removeFirst()
            writers += 1
            nextWriter.resume()
        } else {
            while !readerWaiters.isEmpty {
                let reader = readerWaiters.removeFirst()
                readers += 1
                reader.resume()
            }
        }
    }

    /// Takes the write lock only if nobody holds it now; returns whether it did. Waiters
    /// imply a holder, so this never jumps the queue.
    package func tryWriteLock() -> Bool {
        guard readers == 0, writers == 0 else { return false }
        writers += 1
        return true
    }

    package func writersWaitingForTesting() -> Int {
        writerWaiters.count
    }

    package func withReadLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await readLock()
        do {
            let result = try await body()
            readUnlock()
            return result
        } catch {
            readUnlock()
            throw error
        }
    }

    package func withWriteLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await writeLock()
        do {
            let result = try await body()
            writeUnlock()
            return result
        } catch {
            writeUnlock()
            throw error
        }
    }
}
