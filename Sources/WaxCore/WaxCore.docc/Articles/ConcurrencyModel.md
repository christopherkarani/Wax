# Concurrency Model

Understand the actor-per-subsystem architecture, writer leases, and synchronization primitives.

## Overview

WaxCore uses an **actor-per-subsystem** concurrency model where each major component is an actor with its own serial executor. Shared mutable state is protected by purpose-built synchronization primitives, and I/O is offloaded to a concurrent dispatch queue.

## Actor Isolation

WaxCore's file coordinator is the package-only ``Wax`` actor. It serializes mutation coordination for package internals, but it is not public API. Public consumers should use the top-level `Wax` module APIs instead of depending on this storage actor.

```
┌─────────────────────────────────────┐
│ package-only store actor            │
│                                     │
│  AsyncReadWriteLock (opLock)        │
│  ├── Readers: concurrent            │
│  └── Writer: exclusive (lease)      │
│                                     │
│  BlockingIOExecutor                 │
│  └── run<T>(): blocking POSIX I/O   │
└─────────────────────────────────────┘
```

## Writer Leases

Only one package-internal writer can be active at a time, enforced by a lease system.

The ``WaxWriterPolicy`` enum controls acquisition behavior:

| Policy | Behavior |
|--------|----------|
| `.fail` | Throws ``WaxError/writerBusy`` immediately |
| `.wait` | Suspends until the lease becomes available |
| `.timeout(Duration)` | Waits up to a duration, then throws ``WaxError/writerTimeout`` |

## Synchronization Primitives

WaxCore provides these lock types:

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

### FileLock

Advisory whole-file lock via POSIX `flock` for cross-process synchronization:

```swift
let lock = try FileLock.acquire(at: fileURL, mode: .exclusive, timeout: .seconds(5))
// ... exclusive file access ...
try lock.release()
```

Supports shared (read) and exclusive (write) modes, plus upgrade and downgrade transitions. Blocking acquisition is bounded: omitting `timeout` waits at most `FileLock.defaultAcquireTimeout` (30 seconds), and only an explicit `nil` waits indefinitely. Store opens use `WaxOptions.lockWaitTimeout`, which defaults to the same bound.

## BlockingIOExecutor

The ``BlockingIOExecutor`` offloads file I/O to a concurrent `DispatchQueue`:

- Blocking reads and writes run via `run<T>()`; the owning actor serializes mutations

This separates the async actor world from blocking POSIX I/O, preventing actor thread pool exhaustion.

## Cross-Process Safety

For multi-process access to the same `.wax` file, ``FileLock`` provides advisory locking:

- Multiple processes can hold **shared locks** for concurrent reads
- A process requesting an **exclusive lock** for writes waits until all shared locks are released, up to the lock wait timeout

Combined with the dual-header A/B mirroring, this ensures that a reader never sees a partially-written header even if the writer crashes mid-update.
