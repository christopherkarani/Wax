# Getting Started with WaxCore

Create, open, and interact with `.mv2s` memory files using the Wax actor.

## Overview

WaxCore is the persistence foundation for all Wax modules. Every operation — text indexing, vector search, structured memory — ultimately stores data as **frames** inside a `.mv2s` file managed by the ``Wax`` actor.

## Creating a Store

Use ``Wax/create(at:walSize:options:)`` to create a new `.mv2s` file:

```swift
import WaxCore

let url = URL(filePath: "/path/to/memory.mv2s")
let store = try await Wax.create(at: url)
```

You can customize the WAL ring buffer size and fsync policy:

```swift
let options = WaxOptions(
    fsyncPolicy: .everyBytes(1_048_576),  // fsync every 1 MiB
    enableReplayStateSnapshot: true
)
let store = try await Wax.create(
    at: url,
    walSize: 128 * 1024 * 1024,  // 128 MiB WAL
    options: options
)
```

## Opening an Existing Store

Use ``Wax/open(at:options:)`` to open a previously created file. If the WAL contains uncommitted records, they are automatically replayed during open:

```swift
let store = try await Wax.open(at: url)
```

## Writing Frames

All writes require a **writer lease** — only one writer can be active at a time:

```swift
let lease = try await store.acquireWriterLease(policy: .wait)

let frameId = try await store.putFrame(/* frame data */)

try await store.commit()
store.releaseWriterLease(lease)
```

The writer policy controls what happens when another writer already holds the lease:

- ``WaxWriterPolicy/fail`` — Immediately throws ``WaxError/writerBusy``
- ``WaxWriterPolicy/wait`` — Suspends until the lease becomes available
- ``WaxWriterPolicy/timeout(_:)`` — Waits up to a duration, then throws ``WaxError/writerTimeout``

## Reading Frames

Reads do not require a writer lease and can execute concurrently:

```swift
let stats = await store.stats()
print("Frame count: \(stats.frameCount)")

if let meta = await store.frame(id: 0) {
    let payload = try await store.readPayload(
        at: meta.payloadOffset,
        length: meta.payloadLength
    )
}
```

## Committing Changes

After writing frames, call ``Wax/commit()`` to flush the WAL, write the updated TOC and footer, and update the header:

```swift
try await store.commit()
```

Until a commit, writes exist only in the WAL ring buffer. The WAL provides crash safety — uncommitted records are replayed automatically on next open.

## Closing the Store

Always close the store when done:

```swift
try await store.close()
```
