import Foundation
import os

/// High-performance reader-writer lock using os_unfair_lock.
/// Optimized for read-heavy workloads with minimal lock overhead.
///
/// - Read operations are concurrent and non-blocking when no writer is active
/// - Write operations are exclusive and block all readers/writers
/// - Lock acquisition is ~5-10ns vs ~1-2μs for async continuation-based locks
public final class ReadWriteLock: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var readerCount: Int32 = 0
    private var writerWaiting: Bool = false
    
    public init() {}
    
    // MARK: - Synchronous API (Hot Path)
    
    /// Acquire read lock synchronously.
    /// Multiple readers can hold the lock concurrently.
    @inline(__always)
    public func readLock() {
        os_unfair_lock_lock(&lock)
        readerCount += 1
        os_unfair_lock_unlock(&lock)
    }
    
    /// Release read lock.
    @inline(__always)
    public func readUnlock() {
        os_unfair_lock_lock(&lock)
        readerCount -= 1
        os_unfair_lock_unlock(&lock)
    }
    
    /// Acquire write lock synchronously.
    /// Exclusive access - blocks until all readers release.
    @inline(__always)
    public func writeLock() {
        os_unfair_lock_lock(&lock)
        // Spin until no readers (write starvation possible but acceptable for our workload)
        while readerCount > 0 {
            os_unfair_lock_unlock(&lock)
            // Brief yield to allow readers to complete
            usleep(1)
            os_unfair_lock_lock(&lock)
        }
    }
    
    /// Release write lock.
    @inline(__always)
    public func writeUnlock() {
        os_unfair_lock_unlock(&lock)
    }
    
    /// Execute a read operation under the lock.
    @inline(__always)
    public func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        readLock()
        defer { readUnlock() }
        return try body()
    }
    
    /// Execute a write operation under the lock.
    @inline(__always)
    public func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        writeLock()
        defer { writeUnlock() }
        return try body()
    }
}

/// Async-compatible wrapper around ReadWriteLock.
/// Provides async/await interface while using efficient synchronous locking internally.
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

/// Simple unfair lock wrapper for hot paths requiring minimal overhead.
/// Use when you need the absolute fastest lock (~5ns acquisition).
public final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    
    public init() {}
    
    @inline(__always)
    public func acquire() {
        os_unfair_lock_lock(&_lock)
    }
    
    @inline(__always)
    public func release() {
        os_unfair_lock_unlock(&_lock)
    }
    
    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return try body()
    }
    
    /// Try to acquire lock without blocking.
    /// Returns true if lock was acquired, false otherwise.
    @inline(__always)
    public func tryAcquire() -> Bool {
        os_unfair_lock_trylock(&_lock)
    }
}
