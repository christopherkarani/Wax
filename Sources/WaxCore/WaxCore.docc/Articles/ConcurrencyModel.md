# Concurrency Model

Understand the actor-per-subsystem architecture, writer leases, and synchronization primitives.

## Overview

WaxCore uses an **actor-per-subsystem** concurrency model where each major component is an actor with its own serial executor. Shared mutable state is protected by purpose-built synchronization primitives, and I/O is offloaded to a concurrent dispatch queue.

## Actor Isolation

The ``Wax`` actor is the central coordinator. All frame reads and writes go through it, ensuring sequential consistency for mutations while allowing concurrent reads.

```
┌─────────────────────────────────────┐
│         Wax (actor)                 │
│                                     │
│  AsyncReadWriteLock (opLock)        │
│  ├── Readers: concurrent            │
│  └── Writer: exclusive (lease)      │
│                                     │
│  BlockingIOExecutor                 │
│  ├── run<T>(): concurrent reads     │
│  └── runWrite<T>(): exclusive write │
└─────────────────────────────────────┘
```

## Writer Leases

Only one writer can be active at a time, enforced by a lease system:

```swift
let lease = try await store.acquireWriterLease(policy: .wait)
// ... perform writes ...
store.releaseWriterLease(lease)
```

The ``WaxWriterPolicy`` enum controls acquisition behavior:

| Policy | Behavior |
|--------|----------|
| `.fail` | Throws ``WaxError/writerBusy`` immediately |
| `.wait` | Suspends until the lease becomes available |
| `.timeout(Duration)` | Waits up to a duration, then throws ``WaxError/writerTimeout`` |

## Synchronization Primitives

WaxCore provides several lock types for different use cases:

### AsyncReadWriteLock

An actor-based reader-writer lock using Swift continuations. Writers are prioritized over readers to prevent starvation.

```swift
let lock = AsyncReadWriteLock()
await lock.readLock()
// ... concurrent read ...
lock.readUnlock()

await lock.writeLock()
// ... exclusive write ...
lock.writeUnlock()
```

### AsyncMutex

A simple async mutual exclusion lock using continuations:

```swift
let mutex = AsyncMutex()
await mutex.withLock {
    // ... exclusive access ...
}
```

### ReadWriteLock

A synchronous reader-writer lock backed by `pthread_rwlock_t`. Used on hot paths where async overhead is unacceptable:

```swift
let lock = ReadWriteLock()
lock.readLock()
// ... fast read ...
lock.readUnlock()
```

### UnfairLock

Minimal-overhead lock for the hottest paths. Uses `os_unfair_lock` on Darwin and `pthread_mutex_t` on Linux:

```swift
let lock = UnfairLock()
lock.withLock {
    // ... critical section ...
}
```

### FileLock

Advisory whole-file lock via POSIX `flock` for cross-process synchronization:

```swift
let lock = FileLock()
try lock.acquire(at: fileURL, mode: .exclusive)
// ... exclusive file access ...
lock.release()
```

Supports shared (read) and exclusive (write) modes, plus upgrade and downgrade transitions.

## BlockingIOExecutor

The ``BlockingIOExecutor`` offloads file I/O to a concurrent `DispatchQueue`:

- **Read operations** via `run<T>()` execute concurrently with other reads
- **Write operations** via `runWrite<T>()` use a barrier flag for exclusivity

This separates the async actor world from blocking POSIX I/O, preventing actor thread pool exhaustion.

## Cross-Process Safety

For multi-process access to the same `.wax` file, ``FileLock`` provides advisory locking:

- Multiple processes can hold **shared locks** for concurrent reads
- A process requesting an **exclusive lock** for writes blocks until all shared locks are released

Combined with the dual-header A/B mirroring, this ensures that a reader never sees a partially-written header even if the writer crashes mid-update.
