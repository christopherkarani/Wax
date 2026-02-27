---
sidebar_position: 4
title: "Session Management"
sidebar_label: "Session Management"
---

Use WaxSession for read/write multiplexing and understand writer policies.

## Overview

`WaxSession` provides a unified interface for frame operations, search, and structured memory. It abstracts the difference between read-only and read-write access modes, managing writer leases automatically.

## Session Modes

### Read-Only

Read-only sessions can search and read frames but cannot write:

```swift
let session = WaxSession(
    wax: store,
    mode: .readOnly,
    config: .init()
)

let results = try await session.searchText(query: "meeting", topK: 10)
```

Multiple read-only sessions can operate concurrently.

### Read-Write

Read-write sessions acquire a writer lease for exclusive write access:

```swift
let session = WaxSession(
    wax: store,
    mode: .readWrite(.wait),
    config: .init()
)

try await session.put(text: "New content", timestamp: nowMs)
try await session.commit()
```

Only one read-write session can be active at a time.

## Writer Policies

The writer policy determines what happens when another writer already holds the lease:

| Policy | Behavior |
|--------|----------|
| `.wait` | Suspend until the lease becomes available (default) |
| `.fail` | Immediately throw an error |
| `.timeout(Duration)` | Wait up to a duration, then throw |

```swift
// Fail immediately if another writer is active
let session = WaxSession(wax: store, mode: .readWrite(.fail))

// Wait up to 5 seconds
let session = WaxSession(wax: store, mode: .readWrite(.timeout(.seconds(5))))
```

## Session Configuration

`WaxSession/Config` controls which search features are enabled:

```swift
var config = WaxSession.Config()
config.enableTextSearch = true
config.enableVectorSearch = true
config.enableStructuredMemory = false
config.vectorEnginePreference = .auto
config.vectorMetric = .cosine
config.vectorDimensions = 384
```

## Frame Operations

Write frames with various overloads:

```swift
// Simple text frame
try await session.put(text: "Hello world", timestamp: nowMs)

// Frame with embedding
try await session.put(
    text: "Semantic content",
    timestamp: nowMs,
    embedding: vectorData
)

// Batch write
try await session.putBatch(
    texts: ["doc1", "doc2", "doc3"],
    timestamps: [ts1, ts2, ts3]
)
```

## Search Operations

`WaxSession` delegates search to the unified search system:

```swift
// Full unified search
let response = try await session.search(SearchRequest(
    query: "architecture",
    mode: .hybrid(alpha: 0.5),
    topK: 20
))

// Text-only search
let textResults = try await session.searchText(query: "architecture", topK: 10)
```

## Text Indexing

Manage the FTS5 text index directly:

```swift
// Index a frame's text
try await session.indexText(frameId: 42, text: "Indexed content")

// Batch indexing
try await session.indexTextBatch(
    frameIds: [1, 2, 3],
    texts: ["First", "Second", "Third"]
)

// Remove from index
try await session.removeText(frameId: 42)
```

## Structured Memory

Access the knowledge graph through the session:

```swift
let entityId = try await session.upsertEntity(
    key: EntityKey("alice"),
    kind: "Person",
    aliases: ["Alice S."],
    nowMs: nowMs
)

let factId = try await session.assertFact(
    subject: EntityKey("alice"),
    predicate: PredicateKey("title"),
    object: .string("CTO"),
    valid: StructuredTimeRange(fromMs: startMs, toMs: nil),
    system: StructuredTimeRange(fromMs: nowMs, toMs: nil),
    evidence: []
)
```

## Lifecycle

### Staging and Committing

Stage search indexes for persistence, then commit all changes:

```swift
// Stage indexes (text + vector)
try await session.stage(compact: false)

// Commit everything to disk
try await session.commit(compact: false)
```

The `compact` flag triggers index compaction (VACUUM for SQLite, defragmentation for vectors) before staging.

### Closing

Always close sessions when done:

```swift
try await session.close()
```

This releases the writer lease (if held) and flushes any pending operations.

## Orchestrator Sessions

`MemoryOrchestrator` manages its own internal `WaxSession`. You typically don't need to create sessions directly unless you need lower-level control. The orchestrator's `MemoryOrchestrator/startSession()` and `MemoryOrchestrator/endSession()` methods manage session tagging for analytics and handoff tracking.
