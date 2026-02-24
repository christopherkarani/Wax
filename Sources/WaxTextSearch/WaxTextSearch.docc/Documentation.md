# ``WaxTextSearch``

Full-text search powered by SQLite FTS5 with BM25 scoring and integrated structured memory.

## Overview

WaxTextSearch provides the text search and structured memory persistence layer for Wax. It wraps SQLite's FTS5 (Full-Text Search 5) engine in an actor-based interface with automatic batching, serialization, and a complete knowledge graph system.

The primary entry point is the ``FTS5SearchEngine`` actor, which manages:

- **Full-text indexing** of frame content with automatic batching (flush threshold: 2,048 documents)
- **BM25 search** with relevance-ranked results and contextual snippets
- **Structured memory** storage and querying for entities, facts, and evidence
- **Serialization** to/from SQLite blobs for persistence in `.wax` files

```swift
// Create an in-memory search engine
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
- ``FTS5SearchEngine``

### Search Results

- ``TextSearchResult``

### Structured Memory

- ``FTS5SearchEngine/upsertEntity(key:kind:aliases:nowMs:)``
- ``FTS5SearchEngine/assertFact(subject:predicate:object:valid:system:evidence:)``
- ``FTS5SearchEngine/retractFact(factId:atMs:)``
- ``FTS5SearchEngine/facts(about:predicate:asOf:limit:)``
- ``FTS5SearchEngine/resolveEntities(matchingAlias:limit:)``
- ``FTS5SearchEngine/evidenceFrameIds(subjectKeys:asOf:maxFacts:maxFrames:requireEvidenceSpan:)``
