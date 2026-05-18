# ``WaxTextSearch``

Full-text search powered by SQLite FTS5 with BM25 scoring and integrated structured memory.

## Overview

WaxTextSearch provides the package-only text search and structured memory persistence layer for Wax. It wraps SQLite's FTS5 (Full-Text Search 5) engine in an actor-based interface with automatic batching, serialization, and a complete knowledge graph system.

The ``FTS5SearchEngine`` actor and its search result value are package-only and not public API. Application and downstream package code should use the public Wax memory APIs instead. For Wax contributors, the engine manages:

- **Full-text indexing** of frame content with automatic batching (flush threshold: 2,048 documents)
- **BM25 search** with relevance-ranked results and contextual snippets
- **Structured memory** storage and querying for entities, facts, and evidence
- **Serialization** to/from SQLite blobs for persistence in `.wax` files

```swift
// Package-internal: create an in-memory search engine
let engine = try await FTS5SearchEngine.inMemory()

// Index content
try await engine.index(frameId: 1, text: "Swift concurrency with actors")

// Search
let results = try await engine.search(query: "actors", topK: 10)
for hit in results {
    print("\(hit.frameId): \(hit.score) — \(hit.snippet ?? "")")
}
```

## Topics

### Essentials

- <doc:TextSearchEngine>

### Structured Memory

- <doc:TextSearchEngine>
