import Foundation

/// Async-compatible ReadWriteLock using continuations.
/// Safe for use in Swift Concurrency (no blocking waits).
public actor AsyncReadWriteLock {
    private var readers: Int = 0
    private var writers: Int = 0
    private var writerWaiters: [CheckedContinuation<Void, Never>] = []
    private var readerWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func readLock() async {
        if writers > 0 || !writerWaiters.isEmpty {
            await withCheckedContinuation { continuation in
                readerWaiters.append(continuation)
            }
        } else {
            readers += 1
        }
    }

    public func readUnlock() {
        if readers > 0 {
            readers -= 1
        }
        if readers == 0 && !writerWaiters.isEmpty {
            let nextWriter = writerWaiters.removeFirst()
            writers += 1
            nextWriter.resume()
        }
    }

    public func writeLock() async {
        if readers > 0 || writers > 0 {
            await withCheckedContinuation { continuation in
                writerWaiters.append(continuation)
            }
        } else {
            writers += 1
        }
    }

    public func writeUnlock() {
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

    public func withReadLock<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
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

    public func withWriteLock<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
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
