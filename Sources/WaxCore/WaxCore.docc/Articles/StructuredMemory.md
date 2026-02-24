# Structured Memory

Store and query knowledge as an entity-fact-predicate graph with bitemporal semantics.

## Overview

WaxCore's structured memory system models knowledge as RDF-like triples: **(subject, predicate, object)**. Each fact carries two temporal dimensions — **valid time** (when the fact is semantically true) and **system time** (when the fact was recorded) — enabling point-in-time queries.

The structured memory types defined here are used by the WaxTextSearch module's `FTS5SearchEngine` actor for storage and querying.

## Entity-Fact Model

### Entities

An ``EntityKey`` is an open-world string identifier for any named concept:

```swift
let alice = EntityKey("alice")
let acme = EntityKey("company:acme")
```

Entities have a **kind** (e.g., "Person", "Organization") and zero or more **aliases** for fuzzy matching. Aliases are NFKC-normalized and case-folded for consistent lookup.

### Predicates

A ``PredicateKey`` names a relationship or property:

```swift
let worksAt = PredicateKey("works_at")
let founded = PredicateKey("founded_year")
```

### Fact Values

The ``FactValue`` enum supports seven typed values:

| Case | Description |
|------|-------------|
| `.string(String)` | Text value |
| `.int(Int64)` | Integer value |
| `.double(Double)` | Floating-point value (must be finite) |
| `.bool(Bool)` | Boolean value |
| `.data(Data)` | Binary blob |
| `.timeMs(Int64)` | Timestamp in milliseconds |
| `.entity(EntityKey)` | Reference to another entity |

## Bitemporal Queries

Every fact has two time ranges defined by ``StructuredTimeRange``:

- **Valid time** `[fromMs, toMs)` — When the fact is true in the real world
- **System time** `[fromMs, toMs)` — When the fact was asserted in the system

Use ``StructuredMemoryAsOf`` to query facts at specific points in both time dimensions. A fact matches when the query's system time falls within the system range AND the query's valid time falls within the valid range.

Open-ended ranges (where `toMs` is `nil`) represent facts that remain true indefinitely until retracted.

## Evidence Provenance

Each fact is linked to its source via ``StructuredEvidence``:

```swift
StructuredEvidence(
    sourceFrameId: frameId,
    chunkIndex: 2,
    spanUTF8: 100..<250,
    extractorId: "nlp-v1",
    extractorVersion: "1.0",
    confidence: 0.95,
    assertedAtMs: timestamp
)
```

This provenance chain allows tracing any fact back to the exact text span that produced it.

## Deduplication

Facts are deduplicated by a SHA-256 hash of (subject, predicate, object). Asserting the same triple twice returns the existing ``FactRowID`` rather than creating a duplicate.

## Retraction

Facts can be retracted by closing their system time range:

```swift
try await engine.retractFact(factId: factId, atMs: nowMs)
```

Retraction only affects open-ended spans (where `system_to_ms` is NULL). Retracting an already-closed span is a no-op.
