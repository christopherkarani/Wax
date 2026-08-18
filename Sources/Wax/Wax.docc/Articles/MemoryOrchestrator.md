# Memory Orchestrator

Understand the package-only text RAG orchestrator for contributor work.

## Status

`MemoryOrchestrator` is a package-only implementation detail. It uses Swift `package` access, so it is **not public API** for application or downstream package consumers — external apps should use ``Memory`` instead (see <doc:GettingStarted>).

Use this article as internal implementation documentation for Wax contributors. Public integration docs should wait for a stable public facade or an explicit access-level change.

## Overview

``MemoryOrchestrator`` is the internal engine behind ``Memory``. It coordinates chunking, embedding, indexing, search, and RAG context assembly into a single actor with a high-level API.

## Initialization

```swift
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: config,
    embedder: embedder  // nil for text-only mode
)
```

The orchestrator creates a new `.wax` file if one doesn't exist at the URL, or opens an existing one with automatic crash recovery.

> Note: On a fresh store, `enableVectorSearch` is automatically disabled when no embedder is configured and no committed vector index exists yet. The store runs text-only in that case; `runtimeStats().vectorSearchEnabled` reports the effective state.

## Ingestion Pipeline

When you call `remember(_:metadata:)`, the orchestrator:

1. **Chunks** the text using the configured chunking strategy (default: token-count with 400 tokens and 40-token overlap)
2. **Embeds** each chunk using the embedding provider (if provided), batching through `BatchEmbeddingProvider` when available
3. **Writes** each chunk as a frame to the `.wax` file's write-ahead log (WAL)
4. **Indexes** each chunk's text in the FTS5 full-text search engine
5. **Adds** each chunk's embedding to the live vector search engine and the pending vector set

Writes are **not** committed to the durable indexes on every `remember` call. Call `flush()` (or `close()`, which flushes) to commit the WAL, FTS index, and vector index atomically. In-process searches see pending vectors immediately; durability requires a commit.

### Batching

Ingestion respects two config parameters:

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `ingestBatchSize` | 32 | Chunks per commit batch |
| `ingestConcurrency` | 1 | Parallel embedding tasks |

### Embedding Cache

A bounded LRU cache (default capacity: 2,048) avoids re-embedding identical text within a session.

## Recall

`recall(query:)` returns a ``RAGContext`` assembled within the configured token budget:

```swift
let context = try await orchestrator.recall(query: "project timeline")
```

### Retrieval Mode

Hosts name ``Memory/RetrievalMode`` (`textOnly` / `vectorOnly` / `hybrid`). Hybrid may fall back to text when the vector lane is unavailable; `vectorOnly` throws.

```swift
let context = try await orchestrator.recall(
    query: "timeline",
    mode: .hybrid()
)
```

`recallExecution(...)` reports the requested vs. effective mode and the query-embedding state; the public ``Memory/search(_:options:)`` surfaces the same information via ``RAGContext/diagnostics``.

If query embedding times out, a circuit breaker pauses query embedding for `queryEmbeddingCircuitCooldown` (default 60s), then half-opens and retries — a single success closes it again.

### Frame Filtering

Restrict recall to specific frames:

```swift
let context = try await orchestrator.recall(
    query: "meeting notes",
    mode: .hybrid(),
    frameFilter: FrameFilter(
        metadataFilter: MetadataFilter(requiredEntries: ["kind": "meeting"])
    ),
    timeRange: SearchTimeRange(after: weekAgoMs, before: nil),
    topK: nil
)
```

## Direct Search

For raw search results without RAG assembly, use `search(query:mode:topK:frameFilter:)`:

```swift
let hits = try await orchestrator.search(
    query: "velocity",
    mode: .hybrid(alpha: 0.5),
    topK: 20
)
```

Each hit includes the stored `frameId` and a `metadata` dictionary. If you save
structured records as JSON plus stable identifiers, put the identifier in
metadata and read it back from the returned hit or RAG item after recall.

```swift
if let best = hits.first {
    print(best.metadata["id"] ?? "unknown")
}
```

## Structured Memory

When `enableStructuredMemory` is set in the config:

```swift
// Entities
try await orchestrator.upsertEntity(
    key: EntityKey("alice"),
    kind: "Person",
    aliases: ["Alice Smith"]
)

// Facts
try await orchestrator.assertFact(
    subject: EntityKey("alice"),
    predicate: PredicateKey("role"),
    object: .string("Engineering Lead"),
    evidence: [...]
)

// Queries
let facts = try await orchestrator.facts(
    about: EntityKey("alice"),
    predicate: nil,
    asOfMs: nowMs
)
```

## Session Handoffs

Store and retrieve cross-session handoff records:

```swift
// Save handoff at session end
try await orchestrator.rememberHandoff(
    content: "Current project state summary...",
    project: "my-app",
    pendingTasks: ["Fix login bug", "Add dark mode"],
    sessionId: sessionId
)

// Retrieve at next session start
if let handoff = try await orchestrator.latestHandoff(project: "my-app") {
    print(handoff.content)
    print(handoff.pendingTasks)
}
```

## Runtime Statistics

```swift
let stats = await orchestrator.runtimeStats()
print("Frames: \(stats.frameCount)")
print("Vector search: \(stats.vectorSearchEnabled)")
print("Embedder: \(stats.embedderIdentity?.model ?? "none")")
```

The public equivalent is ``Memory/stats()``.

## Configuration Reference

See `OrchestratorConfig` for the full configuration surface:

| Category | Key Options |
|----------|-------------|
| Search | `enableTextSearch`, `enableVectorSearch`, `enableStructuredMemory` |
| RAG | `rag` (`FastRAGConfig`) |
| Chunking | `chunking` (`ChunkingStrategy`) |
| Embedding | `embeddingCacheCapacity`, `requireOnDeviceProviders`, `queryEmbeddingTimeout`, `queryEmbeddingCircuitCooldown` |
| Vector | Engine selection is internal — Metal HNSW activates at 10,000+ vectors; smaller indexes use an exact CPU flat index |
| Maintenance | `liveSetRewriteSchedule` |
