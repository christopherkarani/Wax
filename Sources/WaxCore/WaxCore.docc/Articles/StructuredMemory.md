# Structured Memory

Understand how Wax stores knowledge as an entity-fact-predicate graph with bitemporal semantics.

## Overview

WaxCore's structured memory system models knowledge as RDF-like triples: **(subject, predicate, object)**. Each fact carries two temporal dimensions — **valid time** (when the fact is semantically true) and **system time** (when the fact was recorded) — enabling point-in-time queries.

The Swift storage types and engine calls behind this model are package-only implementation details, not public API. Downstream applications should use the top-level `Wax` product, the CLI, or the MCP tools for supported structured-memory workflows.

## Entity-Fact Model

### Entities

An entity is an open-world string identifier for any named concept, such as a person, project, document, place, organization, or agent.

Entities have a **kind** (e.g., "Person", "Organization") and zero or more **aliases** for fuzzy matching. Aliases are NFKC-normalized and case-folded for consistent lookup.

### Predicates

A predicate names a relationship or property, such as `works_at`, `founded_year`, `status`, or `mentions`.

### Fact Values

Fact objects are stored with one of the supported scalar or reference forms:

| Case | Description |
|------|-------------|
| String | Text value |
| Integer | Signed integer value |
| Floating point | Finite double-precision value |
| Boolean | True/false value |
| Binary data | Opaque bytes |
| Timestamp | Milliseconds since Unix epoch |
| Entity reference | Link to another entity |

## Bitemporal Queries

Every fact has two time ranges:

- **Valid time** `[fromMs, toMs)` — When the fact is true in the real world
- **System time** `[fromMs, toMs)` — When the fact was asserted in the system

Queries can evaluate facts at specific points in both time dimensions. A fact matches when the query's system time falls within the system range AND the query's valid time falls within the valid range.

Open-ended ranges (where `toMs` is `nil`) represent facts that remain true indefinitely until retracted.

## Evidence Provenance

Each fact can link back to evidence that records the source frame, source chunk, UTF-8 span, extractor identity, confidence, and assertion time.

This provenance chain allows tracing any fact back to the exact text span that produced it.

## Deduplication

Facts are deduplicated by a SHA-256 hash of (subject, predicate, object). Asserting the same triple twice reuses the existing row rather than creating a duplicate.

## Retraction

Facts are retracted by closing their system time range.

Retraction only affects open-ended spans (where `system_to_ms` is NULL). Retracting an already-closed span is a no-op.
