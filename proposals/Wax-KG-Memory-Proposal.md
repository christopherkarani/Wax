# Wax Knowledge Graph + Fact Store Memory Proposal

## Executive Summary
Wax already delivers durable frames, hybrid text+vector search, and RAG context assembly. The next step is a structured memory layer that captures entities, relations, and typed facts with provenance and temporal validity. This adds precision and conflict handling on top of similarity search, enabling reliable long-term memory across sessions while preserving auditability and performance.

This proposal adds:
- A **Fact Store** for typed, versioned facts with provenance and validity windows.
- A lightweight **Knowledge Graph** for entity and relation traversal.
- **Hybrid retrieval fusion** (vector + keyword + graph + time) with deterministic scoring.
- A **maintenance policy** (decay, compaction, reindexing) that preserves truth while pruning noise.

## Goals
- Make long-term memory reliable by modeling temporal truth and provenance.
- Support entity-centric and relation-centric queries.
- Preserve Wax’s performance and correctness guarantees.
- Keep APIs Swifty, typed, and hard to misuse.
- Enable incremental adoption without breaking existing users.

## Non-Goals (v1)
- Full graph query language (SPARQL / Cypher). Provide a Swift DSL instead.
- Cross-device federation or multi-tenant sharding.
- Autonomous crawlers or web ingestion.

---

## Current Wax Capabilities (Baseline)
- Immutable frames + metadata (timeline and WAL).
- Hybrid search: FTS5 + vector + timeline fallback (RRF fusion).
- RAG context builder with deterministic expansion and snippet selection.

Gaps addressed by this proposal:
- No structured fact store or temporal truth model.
- No graph traversal for precise entity relations.
- No conflict resolution beyond timeline filtering.

---

## Architecture Overview

### 1) Fact Store (Source of Truth)
Stores typed facts with provenance and temporal validity. Facts are never deleted, only superseded.

**Key traits**
- Typed values (`String`, `Date`, `Double`, `EntityRef`).
- Provenance linked to frames/chunks.
- Validity windows for “current” vs “past”.
- Confidence score to support uncertain extraction.

### 2) Knowledge Graph (Structure & Traversal)
Entities and relations are stored as first-class nodes/edges. Relations can be temporal and weighted.

**Key traits**
- Canonicalized entities with aliases.
- Relations like `works_at`, `lives_in`, `owns`.
- Traversal depth bounds to avoid explosion.

### 3) Hybrid Retrieval (Fusion)
Parallel retrieval lanes:
- Vector search (semantic recall)
- Keyword search (precision)
- Graph traversal (entity/relational precision)
- Timeline (recency)

Results fuse via weighted RRF with penalties for conflicts and boosts for recency/validity.

---

## Data Model (Swift-First)

### Identifiers
```swift
public struct EntityID: Hashable, Sendable { public let raw: UUID }
public struct FactID: Hashable, Sendable { public let raw: UUID }
public struct EdgeID: Hashable, Sendable { public let raw: UUID }
```

### Entity
```swift
public struct Entity: Sendable {
    public let id: EntityID
    public let type: EntityType
    public let canonicalName: String
    public let aliases: [String]
    public let createdAt: Date
    public let updatedAt: Date
}
```

### Relation
```swift
public struct Relation: Sendable {
    public let id: EdgeID
    public let type: RelationType
    public let from: EntityID
    public let to: EntityID
    public let weight: Double?
    public let validFrom: Date?
    public let validTo: Date?
    public let createdAt: Date
}
```

### Fact
```swift
public struct Fact<Value: FactValue>: Sendable {
    public let id: FactID
    public let subject: EntityID
    public let predicate: FactPredicate
    public let value: Value
    public let confidence: Double
    public let provenance: [Provenance]
    public let validFrom: Date?
    public let validTo: Date?
    public let createdAt: Date
}
```

### FactValue
```swift
public protocol FactValue: Codable, Sendable {}
extension String: FactValue {}
extension Double: FactValue {}
extension Date: FactValue {}
public struct EntityRef: FactValue { public let id: EntityID }
```

### Provenance
```swift
public struct Provenance: Sendable {
    public let sourceFrameId: UInt64
    public let chunkIndex: UInt32
    public let span: TextSpan
    public let extractor: ExtractorID
}
```

---

## Public APIs

### Graph Store
```swift
public protocol GraphStore: Sendable {
    func upsertEntity(_ entity: Entity) async throws
    func upsertRelation(_ relation: Relation) async throws
    func neighbors(of entity: EntityID,
                   relationTypes: Set<RelationType>?,
                   depth: Int) async throws -> [EntityID]
    func relations(from entity: EntityID,
                   type: RelationType?) async throws -> [Relation]
}
```

### Fact Store
```swift
public protocol FactStore: Sendable {
    func upsertFact<V: FactValue>(_ fact: Fact<V>) async throws
    func facts(for subject: EntityID,
               predicate: FactPredicate?) async throws -> [AnyFact]
    func deleteFact(_ id: FactID) async throws
}
```

### Hybrid Retrieval
```swift
public struct HybridQuery: Sendable {
    public let text: String?
    public let entities: [EntityID]?
    public let filters: QueryFilters
    public let graphHints: GraphHints?
}

public protocol HybridRetriever: Sendable {
    func search(_ query: HybridQuery, limit: Int) async throws -> [HybridHit]
}
```

---

## Storage & Indexing Strategy

Recommended v1:
- **SQLite** for entities, relations, facts, provenance.
- **FTS5** for keyword search over facts and entity aliases.
- Use existing Wax vector index for semantic retrieval.

Suggested tables:
- `entities(id, type, name, aliases, created_at, updated_at)`
- `relations(id, type, from_id, to_id, weight, valid_from, valid_to, created_at)`
- `facts(id, subject_id, predicate, value_type, value_blob, confidence, valid_from, valid_to, created_at)`
- `provenance(fact_id, frame_id, chunk_index, span_start, span_end, extractor_id)`
- `entity_aliases(entity_id, alias)`

---

## Conflict Resolution Strategy
- Never overwrite facts; instead mark old facts as `validTo` when superseded.
- Keep both versions with clear temporal ranges.
- Retrieval prefers currently valid facts unless query is temporal.

---

## Maintenance & Decay
- Nightly consolidation: merge redundant facts, normalize aliases.
- Weekly summarization: regenerate entity summaries from facts.
- Monthly reindex: refresh embeddings and rebuild graph edge weights.
- Archive, do not delete; avoid loss of provenance.

---

## Migration Plan

**Phase 0: Schema**
- Add new tables and data types.

**Phase 1: Dual Write**
- Ingestion writes to both KG/fact store and existing indexes.

**Phase 2: Read Opt-In**
- Feature flag hybrid retrieval; expose APIs.

**Phase 3: Default**
- Hybrid retrieval becomes default; legacy path remains fallback.

---

## Testing Strategy (Swift Testing)

Unit:
- Fact encoding/decoding across value types
- Entity/alias canonicalization
- Relation traversal depth bounds

Integration:
- Ingest → facts + graph updates
- Hybrid retrieval fusion correctness
- Temporal conflict resolution

Performance:
- Graph traversal under high degree
- Fusion with 1k/10k candidates

---

## Risks & Mitigations
- **Entity explosion**: canonicalize + soft merge
- **Fact drift**: validity windows + provenance
- **Latency**: bounded traversal, shortlists, async fusion
- **API complexity**: minimal protocols, v1 DSL only

---

## Next Steps
1) Confirm scale/target platforms
2) Implement GraphStore + FactStore
3) Integrate hybrid fusion into `UnifiedSearch`
4) Add Swift Testing suites
5) Ship behind feature flag

