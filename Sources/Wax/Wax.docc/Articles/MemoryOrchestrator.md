# Memory Orchestrator

Configure and use the primary text RAG orchestrator for ingestion and retrieval.

## Overview

``MemoryOrchestrator`` is the main entry point for text-based memory applications. It coordinates chunking, embedding, indexing, search, and RAG context assembly into a single actor with a high-level API.

## Initialization

```swift
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: config,
    embedder: embedder  // nil for text-only mode
)
```

The orchestrator creates a new `.wax` file if one doesn't exist at the URL, or opens an existing one with automatic crash recovery.

## Ingestion Pipeline

When you call ``MemoryOrchestrator/remember(_:metadata:)``, the orchestrator:

1. **Chunks** the text using the configured chunking strategy (default: token-count with 400 tokens and 40-token overlap)
2. **Embeds** each chunk using the embedding provider (if provided), batching through `BatchEmbeddingProvider` when available
3. **Writes** each chunk as a frame to the `.wax` file
4. **Indexes** each chunk's text in the FTS5 full-text search engine
5. **Adds** each chunk's embedding to the vector search engine
6. **Commits** all changes atomically

### Batching

Ingestion respects two config parameters:

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `ingestBatchSize` | 32 | Chunks per commit batch |
| `ingestConcurrency` | 1 | Parallel embedding tasks |

### Embedding Cache

A bounded LRU cache (default capacity: 2,048) avoids re-embedding identical text within a session.

## Recall

``MemoryOrchestrator/recall(query:)`` returns a ``RAGContext`` assembled within the configured token budget:

```swift
let context = try await orchestrator.recall(query: "project timeline")
```

### Embedding Policies

Control when query embeddings are computed:

| Policy | Behavior |
|--------|----------|
| `.never` | Text-only search (no vector lane) |
| `.ifAvailable` | Use vector search if an embedder is configured |
| `.always` | Require vector search; throw if no embedder |

```swift
let context = try await orchestrator.recall(
    query: "timeline",
    embeddingPolicy: .ifAvailable
)
```

### Frame Filtering

Restrict recall to specific frames:

```swift
let context = try await orchestrator.recall(
    query: "meeting notes",
    frameFilter: FrameFilter(
        requiredTags: ["meetings"],
        timeRange: TimeRange(after: weekAgoMs)
    )
)
```

## Direct Search

For raw search results without RAG assembly, use ``MemoryOrchestrator/search(query:mode:topK:frameFilter:)``:

```swift
let hits = try await orchestrator.search(
    query: "velocity",
    mode: .hybrid(alpha: 0.5),
    topK: 20
)
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
let stats = try await orchestrator.runtimeStats()
print("Frames: \(stats.frameCount)")
print("Vector search: \(stats.vectorSearchEnabled)")
print("Embedder: \(stats.embedderIdentity?.model ?? "none")")
```

## Configuration Reference

See ``OrchestratorConfig`` for the full configuration surface:

| Category | Key Options |
|----------|-------------|
| Search | `enableTextSearch`, `enableVectorSearch`, `enableStructuredMemory` |
| RAG | `ragConfig` (``FastRAGConfig``) |
| Chunking | `chunking` (``ChunkingStrategy``) |
| Embedding | `embeddingCacheCapacity`, `requireOnDeviceProviders` |
| Vector | `useMetalVectorSearch`, `vectorEnginePreference` |
| Maintenance | `liveSetRewriteSchedule` |
