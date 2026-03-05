import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// High-performance reader-writer lock backed by `pthread_rwlock_t`.
///
/// Using `pthread_rwlock_t` on all platforms (Darwin and Linux) gives genuine reader
/// concurrency — multiple readers can hold the lock simultaneously. The previous Darwin
/// path used `os_unfair_lock` + a usleep spin which serialised all readers, negating
/// any concurrency benefit over a plain mutex.
package final class ReadWriteLock: @unchecked Sendable {
    private var rwlock = pthread_rwlock_t()

    package init() {
        let result = pthread_rwlock_init(&rwlock, nil)
        precondition(result == 0, "pthread_rwlock_init failed: \(result)")
    }

    deinit {
        _ = pthread_rwlock_destroy(&rwlock)
    }

    // MARK: - Synchronous API (Hot Path)

    @inline(__always)
    package func readLock() {
        while true {
            let result = pthread_rwlock_rdlock(&rwlock)
            if result == 0 { return }
            if result == EINTR { continue }
            fatalError("pthread_rwlock_rdlock failed: \(result)")
        }
    }

    @inline(__always)
    package func readUnlock() {
        let result = pthread_rwlock_unlock(&rwlock)
        precondition(result == 0, "pthread_rwlock_unlock failed: \(result)")
    }

    @inline(__always)
    package func writeLock() {
        while true {
            let result = pthread_rwlock_wrlock(&rwlock)
            if result == 0 { return }
            if result == EINTR { continue }
            fatalError("pthread_rwlock_wrlock failed: \(result)")
        }
    }

    @inline(__always)
    package func writeUnlock() {
        let result = pthread_rwlock_unlock(&rwlock)
        precondition(result == 0, "pthread_rwlock_unlock failed: \(result)")
    }

    @inline(__always)
    package func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        readLock()
        defer { readUnlock() }
        return try body()
    }

    @inline(__always)
    package func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        writeLock()
        defer { writeUnlock() }
        return try body()
    }
}

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

/// Simple lock wrapper for hot paths requiring minimal overhead.
package final class UnfairLock: @unchecked Sendable {
    #if canImport(os)
    private var rawLock = os_unfair_lock()
    #else
    private var mutex = pthread_mutex_t()
    #endif

    package init() {
        #if !canImport(os)
        let result = pthread_mutex_init(&mutex, nil)
        precondition(result == 0, "pthread_mutex_init failed: \(result)")
        #endif
    }

    deinit {
        #if !canImport(os)
        _ = pthread_mutex_destroy(&mutex)
        #endif
    }

    @inline(__always)
    package func acquire() {
        #if canImport(os)
        os_unfair_lock_lock(&rawLock)
        #else
        let result = pthread_mutex_lock(&mutex)
        precondition(result == 0, "pthread_mutex_lock failed: \(result)")
        #endif
    }

    @inline(__always)
    package func release() {
        #if canImport(os)
        os_unfair_lock_unlock(&rawLock)
        #else
        let result = pthread_mutex_unlock(&mutex)
        precondition(result == 0, "pthread_mutex_unlock failed: \(result)")
        #endif
    }

    @inline(__always)
    package func withLock<T>(_ body: () throws -> T) rethrows -> T {
        acquire()
        defer { release() }
        return try body()
    }

    @inline(__always)
    package func tryAcquire() -> Bool {
        #if canImport(os)
        os_unfair_lock_trylock(&rawLock)
        #else
        let result = pthread_mutex_trylock(&mutex)
        if result == 0 { return true }
        if result == EBUSY { return false }
        fatalError("pthread_mutex_trylock failed: \(result)")
        #endif
    }
}
