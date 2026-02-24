---
sidebar_position: 1
title: "Text Search Engine"
sidebar_label: "Text Search Engine"
---

Index text, search with BM25 scoring, and manage structured knowledge — all through a single actor.

## Overview

`FTS5SearchEngine` is an actor that combines SQLite FTS5 full-text search with a complete structured memory system. It handles batching, serialization, and persistence automatically.

## Creating an Engine

There are three ways to create an engine:

```swift
// In-memory (fresh)
let engine = try await FTS5SearchEngine.inMemory()

// From serialized data
let engine = try await FTS5SearchEngine.deserialize(from: savedData)

// From a Wax store
let engine = try await FTS5SearchEngine.load(from: waxStore)
```

## Indexing

Index frame content individually or in batches:

```swift
// Single document
try await engine.index(frameId: 42, text: "Meeting notes from Q4 review")

// Batch (much faster — single transaction for N documents)
try await engine.indexBatch(
    frameIds: [1, 2, 3],
    texts: ["First doc", "Second doc", "Third doc"]
)

// Remove a document
try await engine.remove(frameId: 42)
```

### Batching Strategy

The engine maintains an internal queue of pending operations. Operations are flushed to SQLite in batches:

| Queue | Threshold | Trigger |
|-------|-----------|---------|
| Text index ops | 2,048 documents | Auto-flush on threshold, or on search/serialize/count |
| Structured memory ops | 512 operations | Auto-flush on threshold |

This amortizes transaction overhead while keeping memory usage bounded.

## Searching

Search returns results ranked by BM25 relevance:

```swift
let results = try await engine.search(query: "quarterly review", topK: 10)
```

Each `TextSearchResult` contains:

- **`frameId`** — The matching frame's identifier
- **`score`** — BM25 relevance score (higher is better)
- **`snippet`** — Context around the match with `[` `]` delimiters and `...` for truncation (up to 10 terms)

### Query Syntax

FTS5 supports rich query operators:

| Syntax | Meaning |
|--------|---------|
| `swift actors` | Match both terms (implicit AND) |
| `swift OR actors` | Match either term |
| `"swift actors"` | Exact phrase match |
| `swift*` | Prefix match |

### BM25 Scoring

SQLite FTS5's built-in `bm25()` function provides Okapi BM25 ranking. The engine inverts the raw rank (which is "lower is better") so that returned scores follow a "higher is better" convention. Scores typically range from 0 to 100+, depending on term frequency and document length.

## Structured Memory

The engine also stores and queries an entity-fact knowledge graph. See the WaxCore module's Structured Memory article for the data model.

### Entity Management

```swift
// Create or update an entity
let entityId = try await engine.upsertEntity(
    key: EntityKey("alice"),
    kind: "Person",
    aliases: ["Alice Smith", "A. Smith"],
    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
)

// Fuzzy-match entities by alias
let matches = try await engine.resolveEntities(
    matchingAlias: "alice",
    limit: 10
)
```

### Fact Assertion and Querying

```swift
// Assert a fact with temporal bounds
let factId = try await engine.assertFact(
    subject: EntityKey("alice"),
    predicate: PredicateKey("works_at"),
    object: .string("Acme Corp"),
    valid: StructuredTimeRange(fromMs: startMs, toMs: nil),
    system: StructuredTimeRange(fromMs: nowMs, toMs: nil),
    evidence: [evidence]
)

// Query facts
let result = try await engine.facts(
    about: EntityKey("alice"),
    predicate: nil,
    asOf: StructuredMemoryAsOf(systemTimeMs: nowMs, validTimeMs: nowMs),
    limit: 100
)
```

## Persistence

The engine serializes its entire state as a SQLite database blob:

```swift
// Serialize
let data = try await engine.serialize(compact: true)

// Stage for Wax commit
try await engine.stageForCommit(into: waxStore, compact: false)
```

The `compact` flag runs `VACUUM` to reclaim unused space before serialization.

## Schema

The engine uses the following SQLite tables:

| Table | Purpose |
|-------|---------|
| `frames_fts` | FTS5 virtual table for full-text search |
| `frame_mapping` | Maps frame IDs to FTS5 rowids |
| `sm_entity` | Named entities with unique keys |
| `sm_entity_alias` | Normalized aliases for fuzzy entity lookup |
| `sm_predicate` | Relationship/property types |
| `sm_fact` | RDF-like triples with bitemporal spans |
| `sm_fact_span` | Temporal scopes for facts |
| `sm_evidence` | Provenance links to source frames |

The database uses application ID `0x57415854` ("WAXT") and schema version 2.
