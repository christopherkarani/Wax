# Wax Structured Memory (KG + Fact Ledger) Implementation Plan

Status: Draft (implementation-ready after Milestone 0 sign-off)

This plan is written for coding agents working in the Wax repo. It assumes:
- Wax persists indexes as embedded blobs inside a single `.mv2s` file (no external sidecars).
- The lexical index is an in-memory SQLite database serialized via `sqlite3_serialize` and staged through `Wax.stageLexIndexForNextCommit(...)`.
- The current lexical SQLite schema is owned by `WaxTextSearch` (`FTS5SearchEngine` + `FTS5Schema`).

Key integration constraint (do not ignore):
- If structured memory shares the same SQLite blob as FTS, there must be exactly ONE engine responsible for mutating + serializing that blob. We cannot have separate engines that independently deserialize/mutate/serialize the same bytes without losing each other’s changes.

---

## 0) Goals / Non-goals / Invariants

### Goals
- Add a structured memory layer that stores:
  - Entities + aliases
  - Typed facts (scalar or entity-valued) with provenance pointing to Wax frames/chunks
  - Temporal semantics: validity windows + retractions (at minimum)
- Keep everything inside the existing single-file Wax container.
- Make reads deterministic and budgeted (bounded traversal, stable ordering, explicit *as-of* time).
- Keep APIs Swifty, strongly typed, hard to misuse; prefer compile-time guarantees.
- Make structured memory a first-class retrieval surface (always-on in v1).
- leverage swift Generics/protocols and type system

### Non-goals (v1)
- Full Cypher/SPARQL query language.
- Cross-file federation / multi-tenant sharding.
- LLM extraction as a required dependency for correctness (LLM can be optional/plug-in, never in core test paths).

### Invariants (v1)
- No implicit “now” in ranking/temporal filters. All structured-memory queries accept an explicit `StructuredMemoryAsOf`.
- Facts are not deleted in the normal path; they are superseded/retracted.
- Compliance redaction is an explicit future operation; it is a v1 non-goal.
- Deterministic ordering for all query APIs: stable tie-break keys must be specified and tested.
- Retrieval is deterministic for fixed corpora + fixed request inputs (including `asOf`) and must be test-locked.

---

## 1) Architecture Decision (Single-file, No Sidecars)

### Extend the existing lexical SQLite DB blob
We add new tables to the same SQLite database currently used for FTS5.

Pros:
- No WaxCore file-format changes.
- Atomic persistence with existing `stageLexIndexForNextCommit(...)`.
- One backup/restore unit (still a single `.mv2s` file).

Cons / constraints:
- Whole-DB serialize/deserialize cost grows with data size.
- Lex index blob is bounded by `Constants.maxBlobBytes` (currently 256 MiB) via `Wax.stageLexIndexForNextCommit`.
- Requires a unified “lex engine” that owns all writes (text + structured memory).
- v1 behavior when exceeding the size cap:
  - staging/commit must fail with a clear, actionable error recommending orchestrator maintenance (`maintainIfNeeded(policy:)`) and/or future Option B migration.


## 2) Semantics Spec (must be locked in Milestone 0)

### Time model
- Represent time as `Int64` unix milliseconds.
- Use half-open intervals: `[start, end)` where `end == nil` means open-ended (+infinity).

We support two time axes:
- Valid time: when the statement is true “in the world”.
- System time: when Wax recorded/accepted the statement.

v1 minimum:
- System-time visibility (assert/retract) is required.
- Valid-time is supported and **explicit**, but can be made ergonomic via an initializer that sets valid==system (still no implicit “now”).

### Query-time semantics (MUST be unambiguous)
All read APIs accept a single explicit *as-of* value that contains **both** axes:
- `systemTimeMs`: visibility in Wax’s ledger (“what did Wax believe at time T?”)
- `validTimeMs`: visibility in the modeled world (“what was true in the world at time T?”)

Visibility rule (v1):
- A span is visible iff:
  - `system_from_ms <= systemTimeMs < coalesce(system_to_ms, +∞)` **AND**
  - `valid_from_ms <= validTimeMs < coalesce(valid_to_ms, +∞)`

Ergonomics rule (v1):
- No implicit “now”. Provide `StructuredMemoryAsOf(asOfMs:)` which sets `systemTimeMs == validTimeMs == asOfMs`.

### Retraction vs supersession
- Retraction: closes an *open* span by setting `system_to_ms = T` (system-time). Retraction is idempotent.
- Retraction with `T <= system_from_ms` is an error in v1 (disallows time-travel edits unless explicitly modeled).
- Supersession: a convenience for “close old span and open new span” for the same conceptual key.

### Predicate cardinality + supersession policy (v1)
RAG needs “current value” semantics for some predicates (e.g. email, title) without requiring explicit user retractions.

Policy (v1):
- Default: predicates are multi-valued (append-only). Multiple visible facts for the same `(subject, predicate)` are allowed.
- For a small set of “functional” predicates (known keys only), ingestion uses **system-time supersession**:
  - When asserting a new value at `system_from_ms = T`, close all currently-open spans for the same **statement key**:
    - statement key = `(subject_entity_id, predicate_id, qualifiers_hash)` (qualifiers may be NULL in v1)
  - Then open the new span at `T`.

This keeps history while ensuring `.latest` returns a single value for functional predicates under normal ingestion.

### Compliance redaction (explicit)
v1 decision:
1) **Not supported in v1 (documented).**

Rationale (v1):
- Correct redaction is cross-cutting (frame payloads, previews/surrogates, FTS, vectors/embeddings, structured facts/evidence, and persistence). Shipping partial redaction is worse than shipping none.

Future (v2+):
- “tombstone + index scrubbing” is the expected direction:
  - remove sensitive payloads from all retrieval surfaces (FTS / previews / surrogates / structured / vectors).
  - keep minimal tombstone metadata only if legally permissible.

---

## 3) Data Model (Swift 6.2)

### Open-world identifiers
- Entities and predicates must be open-world (string-backed keys), not closed enums.
- Provide ergonomic “known keys” as static constants layered on top of open-world keys.

Proposed shared public types (in `Sources/WaxCore/StructuredMemory/`):
- `EntityKey` (`RawRepresentable<String>`, `Hashable`, `Codable`, `Sendable`)
- `PredicateKey` (same)
- `FactRowID` (`RawRepresentable<Int64>` or `UInt64`), stable DB row id wrapper
- `FactTime` (`RawRepresentable<Int64>`)
- `FactValue` as a closed sum type for storage safety:
  - `.string(String)`
  - `.int(Int64)`
  - `.double(Double)`
  - `.bool(Bool)`
  - `.data(Data)`
  - `.timeMs(Int64)` (for date/time)
  - `.entity(EntityKey)`

### Canonicalization + hashing (MUST be locked)
We need stable hashes for dedupe and deterministic behavior across platforms/builds.

Hash algorithm (v1):
- Use SHA-256 (CryptoKit) for both `fact_hash` and `span_key_hash`.

Canonical encoding (v1, minimal and explicit):
- All hashes are computed over a byte buffer built from fixed, tagged fields (no JSON, no locale-dependent formatting).
- Strings:
  - Normalize to `NFKC` via `precomposedStringWithCompatibilityMapping`.
  - Then fold with `.caseInsensitive` + `.diacriticInsensitive` using `Locale(identifier: "en_US_POSIX")`.
  - Encode as UTF-8 bytes.
- `Double`:
  - Reject non-finite values (NaN/±Inf) for storage; treat as API error.
  - Canonicalize `-0.0` to `+0.0`.
  - Encode IEEE-754 bitPattern as 8 bytes (little-endian).
- `Bool`: encode as a single byte `0x00` / `0x01`.
- Integers/times: encode as fixed-width little-endian 8 bytes (`Int64`).
- `Data`: include raw bytes as-is.
- Entity/predicate keys: treated as normalized strings (same rules).
- `qualifiers_hash`: v1 can remain `NULL` always, but if/when introduced it must be a stable hash of a sorted list of (key,value) pairs encoded with the same rules.

### Alias normalization (MUST be deterministic)
`alias_norm` is **not** user-facing; it is a stable matching key:
- Apply the same string canonicalization rules as hashing (NFKC + fold with en_US_POSIX).
- Trim leading/trailing whitespace.
- Collapse internal whitespace to a single ASCII space.

### Provenance model
Provenance points back to Wax:
- `source_frame_id` (UInt64 stored as Int64 in SQLite)
- `chunk_index` (UInt32 stored as Int64)
- `span_start_utf8` / `span_end_utf8` (Int64 offsets; avoid `String.Index`)
- `extractor_id` (string)
- `extractor_version` (string)

Frame-id range invariant:
- Evidence must only reference frame IDs representable in SQLite `INTEGER` (`UInt64 <= Int64.max`). Insertion should fail with a clear error if violated (this mirrors existing text-search indexing constraints).

---

## 4) SQLite Schema (Option A: inside existing lex DB)

We keep existing FTS tables (`frames_fts`, `frame_mapping`) and add the following tables.

### 4.1 Migrations strategy
- Keep `PRAGMA application_id = FTS5Schema.applicationId` (same DB identity).
- Bump `PRAGMA user_version` from 1 to 2.
- `FTS5Schema.validateOrUpgrade(in:)` becomes a real migration runner:
  - if `user_version == 1`: create new tables + indexes; set `user_version = 2`
  - continue to accept legacy blobs where `application_id == 0 && user_version == 0`, then apply identity + migrate to 2
- Enforce referential integrity:
  - `PRAGMA foreign_keys = ON` must be set in the `DatabaseQueue` configuration (and tested).

Evidence dedupe policy (v1):
- Do **not** enforce evidence uniqueness via a UNIQUE constraint in v1.
- Dedupe at read-time (grouping + stable ordering) for retrieval use-cases.
- Future (v2+): add `evidence_hash BLOB(32)` and UNIQUE if duplicates become operationally significant.

### 4.2 Tables (DDL sketch)

```sql
-- Entities
CREATE TABLE IF NOT EXISTS sm_entity (
  entity_id            INTEGER PRIMARY KEY,
  key                  TEXT NOT NULL,
  kind                 TEXT NOT NULL DEFAULT '',
  created_at_ms        INTEGER NOT NULL,
  UNIQUE(key)
);

CREATE TABLE IF NOT EXISTS sm_entity_alias (
  alias_id             INTEGER PRIMARY KEY,
  entity_id            INTEGER NOT NULL REFERENCES sm_entity(entity_id) ON DELETE CASCADE,
  alias                TEXT NOT NULL,
  alias_norm           TEXT NOT NULL,
  created_at_ms        INTEGER NOT NULL,
  UNIQUE(entity_id, alias_norm)
);

-- Predicates (open-world)
CREATE TABLE IF NOT EXISTS sm_predicate (
  predicate_id         INTEGER PRIMARY KEY,
  key                  TEXT NOT NULL,
  created_at_ms        INTEGER NOT NULL,
  UNIQUE(key)
);

-- Facts are de-duped propositions (subject, predicate, object, qualifiersHash).
-- The object is stored in typed columns for indexability.
CREATE TABLE IF NOT EXISTS sm_fact (
  fact_id              INTEGER PRIMARY KEY,
  subject_entity_id    INTEGER NOT NULL REFERENCES sm_entity(entity_id) ON DELETE RESTRICT,
  predicate_id         INTEGER NOT NULL REFERENCES sm_predicate(predicate_id) ON DELETE RESTRICT,

  object_kind          INTEGER NOT NULL, -- 1=text,2=int,3=double,4=bool,5=data,6=time_ms,7=entity
  object_text          TEXT,
  object_int           INTEGER,
  object_real          REAL,
  object_bool          INTEGER,
  object_blob          BLOB,
  object_time_ms       INTEGER,
  object_entity_id     INTEGER REFERENCES sm_entity(entity_id) ON DELETE RESTRICT,

  qualifiers_hash      BLOB,            -- optional (v1 can be NULL always)
  fact_hash            BLOB NOT NULL,   -- sha256 of canonical (s,p,o,qualifiers)
  created_at_ms        INTEGER NOT NULL,

  CHECK (length(fact_hash) == 32),
  CHECK (qualifiers_hash IS NULL OR length(qualifiers_hash) == 32),

  CHECK (
    (object_kind == 1 AND object_text IS NOT NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
    (object_kind == 2 AND object_text IS NULL AND object_int IS NOT NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
    (object_kind == 3 AND object_text IS NULL AND object_int IS NULL AND object_real IS NOT NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
    (object_kind == 4 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IN (0,1) AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
    (object_kind == 5 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NOT NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
    (object_kind == 6 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NOT NULL AND object_entity_id IS NULL) OR
    (object_kind == 7 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NOT NULL)
  ),
  UNIQUE(fact_hash)
);

-- Spans encode bitemporal-ish ledger: valid time + system time.
CREATE TABLE IF NOT EXISTS sm_fact_span (
  span_id              INTEGER PRIMARY KEY,
  fact_id              INTEGER NOT NULL REFERENCES sm_fact(fact_id) ON DELETE CASCADE,

  valid_from_ms        INTEGER NOT NULL,
  valid_to_ms          INTEGER,         -- NULL = open-ended
  CHECK(valid_to_ms IS NULL OR valid_to_ms > valid_from_ms),

  system_from_ms       INTEGER NOT NULL,
  system_to_ms         INTEGER,         -- NULL = current
  CHECK(system_to_ms IS NULL OR system_to_ms > system_from_ms),

  -- Stable identity for a span that remains valid even after retraction (i.e. when system_to_ms changes).
  -- v1 encodes: hash(fact_id, valid_from_ms, coalesce(valid_to_ms,-1), system_from_ms)
  span_key_hash        BLOB NOT NULL,
  created_at_ms        INTEGER NOT NULL,
  CHECK (length(span_key_hash) == 32),
  UNIQUE(span_key_hash)
);

-- Evidence (provenance), attach to span (preferred) or fact (fallback).
CREATE TABLE IF NOT EXISTS sm_evidence (
  evidence_id          INTEGER PRIMARY KEY,
  span_id              INTEGER REFERENCES sm_fact_span(span_id) ON DELETE CASCADE,
  fact_id              INTEGER REFERENCES sm_fact(fact_id) ON DELETE CASCADE,

  source_frame_id      INTEGER NOT NULL,
  chunk_index          INTEGER,
  span_start_utf8      INTEGER,
  span_end_utf8        INTEGER,

  extractor_id         TEXT NOT NULL,
  extractor_version    TEXT NOT NULL,

  confidence           REAL,
  asserted_at_ms       INTEGER NOT NULL,
  created_at_ms        INTEGER NOT NULL,

  CHECK ((span_id IS NOT NULL) != (fact_id IS NOT NULL))
);
```

### 4.3 Indexes (v1 required)

```sql
CREATE INDEX IF NOT EXISTS sm_entity_key_idx ON sm_entity(key);
CREATE INDEX IF NOT EXISTS sm_entity_alias_norm_idx ON sm_entity_alias(alias_norm);
CREATE INDEX IF NOT EXISTS sm_predicate_key_idx ON sm_predicate(key);

-- “facts about entity” queries
CREATE INDEX IF NOT EXISTS sm_fact_subject_pred_idx ON sm_fact(subject_entity_id, predicate_id);

-- entity-valued edges (outbound)
CREATE INDEX IF NOT EXISTS sm_fact_edge_out_idx
  ON sm_fact(subject_entity_id, predicate_id, object_entity_id)
  WHERE object_kind == 7;

-- entity-valued edges (inbound)
CREATE INDEX IF NOT EXISTS sm_fact_edge_in_idx
  ON sm_fact(object_entity_id, predicate_id, subject_entity_id)
  WHERE object_kind == 7;

-- current span filter fast-path
CREATE INDEX IF NOT EXISTS sm_span_current_fact_idx
  ON sm_fact_span(fact_id, system_from_ms, valid_from_ms, valid_to_ms)
  WHERE system_to_ms IS NULL;

-- provenance lookups
CREATE INDEX IF NOT EXISTS sm_evidence_span_idx ON sm_evidence(span_id) WHERE span_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sm_evidence_fact_idx ON sm_evidence(fact_id) WHERE fact_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sm_evidence_frame_idx ON sm_evidence(source_frame_id);
```

---

## 5) Engine Refactor (single writer for the lex SQLite DB)

### 5.1 Refactor target
Refactor `FTS5SearchEngine` into a more general “lex index engine” that can own both:
- FTS indexing/search
- Structured memory inserts/queries

Concrete approach:
- Keep the public type name `FTS5SearchEngine` for compatibility (v1), but:
  - Move FTS-only internals into a nested helper `FTSIndex` (private).
  - Add a new nested helper `StructuredMemoryIndex` (private).
  - Both share the same `DatabaseQueue` and the same `serialize/stageForCommit` logic.

Hard rule:
- `serialize()` must include both FTS and structured memory changes because they are the same SQLite DB.

### 5.2 Concurrency + batching
- Keep one actor (`FTS5SearchEngine`) as the sole mutation point.
- Add separate buffered pending-op queues for:
  - FTS ops (already exists)
  - structured memory ops (new)
- Flush both in one DB write transaction when either hits a threshold, and always flush before any read.
- Clarify terminology (to avoid perf confusion):
  - “Flush” == apply pending ops into the in-memory SQLite DB (transactional, **not** full-DB serialization).
  - Full-DB serialization happens only during `serialize(...)` / `stageForCommit(...)`.
- Ensure SQLite integrity pragmas are set once per connection:
  - `PRAGMA foreign_keys=ON` (required by schema’s FK constraints).

---

## 6) Public API Surface (Wax-facing)

### 6.1 New API entry points (v1)

Add a new session wrapper (preferred) that reuses the same engine:
- All structured-memory public model types (`EntityKey`, `FactValue`, `StructuredMemoryAsOf`, hits/results, etc.) should live in `WaxCore` so the `Wax` API does not expose `WaxTextSearch.*`-qualified types to consumers.
- `Sources/Wax/StructuredMemorySession.swift`:
  - `public actor WaxStructuredMemorySession { let engine: FTS5SearchEngine; ... }`
  - It is created via `Wax.structuredMemory()` and requires that the lex engine is available (same as text search).

Alternatively (simpler but mixes concerns):
- Extend `WaxTextSearchSession` with structured memory methods and keep a single session.

### 6.2 Store operations (minimum)

```swift
public struct StructuredMemoryAsOf: Sendable, Equatable {
    public var systemTimeMs: Int64
    public var validTimeMs: Int64

    public init(systemTimeMs: Int64, validTimeMs: Int64) {
        self.systemTimeMs = systemTimeMs
        self.validTimeMs = validTimeMs
    }

    /// Convenience initializer that keeps time explicit while setting valid==system.
    public init(asOfMs: Int64) {
        self.systemTimeMs = asOfMs
        self.validTimeMs = asOfMs
    }

    /// Deterministic “latest” sentinel (never wall-clock).
    public static var latest: StructuredMemoryAsOf { .init(asOfMs: .max) }
}

public struct StructuredMemoryQueryContext: Sendable, Equatable {
    public var asOf: StructuredMemoryAsOf
    public var maxResults: Int
    public var maxTraversalEdges: Int
    public var maxDepth: Int
}

public struct StructuredFact: Sendable, Equatable {
    public var subject: EntityKey
    public var predicate: PredicateKey
    public var object: FactValue
}

public struct StructuredFactHit: Sendable, Equatable {
    public var factId: Int64
    public var fact: StructuredFact
    public var evidence: [StructuredEvidence]   // optional; can be lazily loaded
    /// True iff the underlying span is “open-ended” on both axes (`system_to_ms IS NULL && valid_to_ms IS NULL`).
    public var isOpenEnded: Bool
}

public struct StructuredFactsResult: Sendable, Equatable {
    public var hits: [StructuredFactHit]
    public var wasTruncated: Bool
}

public enum StructuredEdgeDirection: Sendable, Equatable {
    case outbound
    case inbound
}

public struct EdgeHit: Sendable, Equatable {
    public var factId: Int64
    public var predicate: PredicateKey
    public var direction: StructuredEdgeDirection
    public var neighbor: EntityKey
}

public struct StructuredEdgesResult: Sendable, Equatable {
    public var hits: [EdgeHit]
    public var wasTruncated: Bool
}

public struct StructuredEvidence: Sendable, Equatable {
    public var sourceFrameId: UInt64
    public var chunkIndex: UInt32?
    public var spanUTF8: Range<Int>?
    public var extractorId: String
    public var extractorVersion: String
    public var confidence: Double?
    public var assertedAtMs: Int64
}
```

Engine API (called by the session):
- `upsertEntity(key:kind:aliases:nowMs:) -> EntityRowID`
- `assertFact(subject:predicate:object:valid:system:provenance:) -> FactRowID` (append-only)
- `upsertFunctionalFact(subject:predicate:object:valid:system:provenance:) -> FactRowID` (closes open spans for same statement key, then asserts)
- `retractSpan(spanId:at:)` (system_to)
- `facts(about:predicate:asOf:limit:) -> StructuredFactsResult` (deterministic sort + truncation)
- `neighbors(of:predicates:asOf:budget:) -> StructuredEdgesResult` (bounded + truncation)

Deterministic ordering spec:
- For facts: sort by `(predicate_key ASC, object_kind ASC, object_value_canonical ASC, span.valid_from_ms DESC, fact_id ASC)`.
- For edges: sort by `(predicate_key ASC, neighbor_entity_key ASC, span.valid_from_ms DESC, fact_id ASC)`.

---

## 7) Retrieval Integration (always-on)

### 7.1 Minimal v1 integration path (safe)
Add a structured-memory “candidate frame id” lane in `Wax.search` (always-on):
- It contributes additional frame IDs sourced from evidence rows pointing to frames.
- Fusion stays the same: weighted RRF list fusion with stable tie-breaks.

Concrete steps:
- Add `SearchRequest.asOfMs: Int64` (default `Int64.max` meaning “latest”; no wall-clock default).
- Add `SearchRequest.structuredMemory: StructuredMemorySearchOptions` (non-optional, defaulted).
- Always run the lane when `request.query` is present and non-empty:
  - Resolve entity candidates via alias matching against the query (simple v1 heuristic).
  - Fetch top-N facts and their evidence using `StructuredMemoryAsOf` derived from request inputs (see below).
  - Produce a ranked list of `sourceFrameId` (stable ordering).
  - Add as another list into `HybridSearch.rrfFusion`.
- Signal-gating rule (v1):
  - If alias matching yields zero entity candidates (or budgets produce zero evidence frames), contribute an empty list so fusion remains unaffected.

`StructuredMemorySearchOptions` (v1):
- `weight: Float` (RRF lane weight; defaults to a conservative value)
- `maxEntityCandidates: Int`
- `maxFacts: Int`
- `maxEvidenceFrames: Int`
- `requireEvidenceSpan: Bool` (if true, only include evidence with spans; default false)

As-of derivation for search (v1):
- `StructuredMemoryAsOf` for retrieval should use the same temporal semantics as search filtering:
  - If `request.timeRange?.before` is set, use `StructuredMemoryAsOf(asOfMs: before)` (query “as of the latest allowed time”).
  - Else use `StructuredMemoryAsOf(asOfMs: request.asOfMs)` (default `Int64.max`).

Testing note:
- Any determinism-sensitive test MUST pass an explicit `asOfMs` (e.g. derived from fixture timestamps) rather than relying on defaults, so that future ingestion changes do not invalidate test expectations.

Alias matching algorithm (v1, deterministic):
- Compute `alias_norm` for:
  - the full query string
  - each token from the query, where tokens are split on whitespace and ASCII punctuation and must be length ≥ 2 after trimming
- Query `sm_entity_alias` for exact matches on `alias_norm`.
- Candidate entity ordering:
  - sort by `(match_source_rank ASC, alias_length DESC, entity_key ASC)` where match_source_rank prefers full-query matches over token matches.
- Cap by `StructuredMemorySearchOptions.maxEntityCandidates`.

Evidence frame ranking (v1, deterministic):
- For selected visible spans/facts, gather evidence rows and group by `source_frame_id`.
- Rank frames by:
  1) `max(confidence)` (NULL treated as -∞) DESC
  2) `max(asserted_at_ms)` DESC
  3) `count(DISTINCT fact_id)` DESC
  4) `source_frame_id` ASC
- Then take top `StructuredMemorySearchOptions.maxEvidenceFrames`.

### 7.2 RAG integration (optional v1.1)
In `FastRAGContextBuilder`, add a new `RAGContext.Item.Kind` (or reuse `.snippet`) for “fact cards”:
- Provide a deterministic textual rendering of top facts (and/or include supporting snippet from evidence frames).
- Keep token counting deterministic by treating rendered facts as plain text snippets.

### 7.3 Context recipe API (recommended for best on-device RAG)
On-device RAG needs more than “snippets + optional surrogates”. Add an explicit, deterministic **recipe** surface that:
- Stages retrieval into lanes (e.g. surrogates, snippets, fact cards) with **separate budgets**.
- Defines stable ordering across lanes, with stable tie-breaks within each lane.
- Keeps evolution safe: defaults can change by swapping recipes, not by adding more booleans.

Recipe requirements (v1):
- Pure config (no hidden heuristics).
- Deterministic rendering for “fact cards” so token counting stays stable + testable.
- Lane budgeting is explicit (total budget + per-lane caps + per-item caps).

---

## 8) Ingestion (Extractor interface) - timeboxed

v1 should not require an LLM. Provide a deterministic reference extractor.

### 8.1 Extractor protocol
- `StructuredMemoryExtractor` returns `(entities, facts, evidence)` given a chunk frame payload + metadata.
- It must be pure/deterministic for tests (no network, no time-now).

### 8.2 Default reference extractor (v1)
Start small:
- Entity: session id, document id, and simple “contact card” patterns (email/phone) if present.
- Facts: “hasEmail”, “hasPhone”, “sessionId”, “documentTitle” etc.
- Evidence: always points to the chunk frame id + byte offsets if possible.

### 8.3 MemoryOrchestrator integration
- Add a first-class structured memory ingestion stage to the orchestrator pipeline (always-on).
- Ensure ingestion is **streaming, budgeted, and deterministic**:
  - extractor uses provided `nowMs` from orchestrator (or injected clock), never calls `Date()` internally.
  - commit order is stable (chunk index order), independent of concurrency.
  - all lex SQLite mutations remain single-writer through the shared engine/queue.
- Return a first-class `MemoryIngestionReport` from `remember(...)` describing budgets, truncations, and counts.

Durability + lifecycle (align with existing Wax semantics):
- `remember(...)` may stage index blobs but should not be required to call `wax.commit()` per call.
- `flush()` / `close()` remain the durability boundary (stage text/vector/structured, then commit).
- `recall(...)` must ensure the lex index is staged so retrieval sees all pending FTS + structured ops.

### 8.4 MemoryOrchestrator staged pipeline (best on-device RAG) (v1)
Treat `MemoryOrchestrator` as the *single deterministic pipeline* that produces all retrieval surfaces (FTS, vectors, structured memory) from the same input.

Core goal:
- Bound in-flight memory (avoid O(totalChunks) intermediate buffers).
- Overlap CPU work (embedding + extraction) with IO/indexing.
- Preserve deterministic ordering and reproducible truncation semantics.

Pipeline phases (v1, stable order):
1) **Plan**
   - Compute `nowMs` once.
   - Build an `IngestionPlan` from budgets + chunking strategy.
2) **Chunk**
   - Chunk deterministically.
   - If chunk budget is exceeded, truncate deterministically and record the decision.
3) **Prepare (concurrent)**
   - For each batch (stable `batchIndex`):
     - build chunk frame options + payload
     - compute embeddings (if enabled)
     - run structured extraction (entities/facts/evidence)
   - Concurrency is bounded and split by workload class:
     - embeddings: limited (often the heaviest)
     - extraction: limited (usually lighter but still bounded)
4) **Commit (ordered, streaming)**
   - Maintain a bounded reorder buffer keyed by `batchIndex`.
   - Commit batches strictly in increasing `batchIndex`:
     - write frames (vector + frames, or frames-only)
     - index text (FTS)
     - apply structured memory writes for the same committed frames
   - Avoid “commit storms”: stage/commit on a policy boundary (e.g. every N batches or bytes), not per chunk.
5) **Finalize**
   - Trigger optional maintenance hooks under explicit policy (see §10.4).
   - Return `MemoryIngestionReport`.

Budgets + backpressure (v1):
- Input: `maxTotalUTF8Bytes`, `maxChunkCount`
- Embeddings: `maxEmbeddings`, `maxEmbeddingWallTimeMs` (soft), `embeddingParallelism`
- Structured: `maxFactsPerChunk`, `maxEvidencePerFact`, `maxEntitiesPerChunk`
- Pipeline: `maxPreparedBatchesInFlight`, `maxLexPendingBytes`
- Optional overall deadline: `maxWallTimeMs` (stop scheduling new batches; commit any already-prepared batches that can be committed deterministically)

### 8.5 Ingestion report (first-class, deterministic) (v1)
- Must be deterministic for the same inputs + budgets:
  - stable counts (chunks ingested, embeddings computed/cache hits, facts/evidence inserted)
  - stable truncation flags + stable “skip reasons” codes for dropped items
- Must include coarse per-phase timings (monotonic durations; wall clock timestamps are optional and must be explicitly enabled).

### 8.6 Maintenance hook surface (policy-driven) (v1)
- Expose an explicit, policy-driven hook API (e.g. `orchestrator.maintainIfNeeded(policy:)`) for:
  - surrogate refresh for newly ingested chunks (bounded)
  - compaction/VACUUM (rare; size-threshold driven)
  - blob-size guardrail handling (see §10.3)

---

## 9) Tests (Swift Testing framework, TDD)

All implementation work starts with failing tests.

### 9.1 Contract tests (in-memory engine)
Add `Tests/WaxIntegrationTests/StructuredMemoryEngineTests.swift`:
- schema creation + identity pragmas (`application_id`, `user_version == 2`)
- migration matrix:
  - legacy `application_id=0/user_version=0` upgrades to v2
  - v1 `user_version=1` upgrades to v2
  - already-v2 is a no-op
  - upgrades are idempotent (running twice does not change results)
  - FTS search outputs remain unchanged after upgrade
- foreign key enforcement is enabled (`PRAGMA foreign_keys=ON`) and constraints behave as expected
- entity upsert + alias normalization + deterministic lookup
- fact assert + “current as-of” query behavior
- bitemporal boundary tests (half-open intervals):
  - query exactly at `*_from_ms` includes; query exactly at `*_to_ms` excludes
- retract closes `system_to_ms` and excludes from later queries; retract is idempotent
- determinism: stable ordering for ties (entity insertion order must not affect query order)
- persistence: serialize/deserialize round-trip preserves facts/evidence

### 9.2 End-to-end tests (Wax file)
Add `Tests/WaxIntegrationTests/StructuredMemoryWaxPersistenceTests.swift`:
- write facts, stage lex index, commit, reopen Wax, query facts, verify results
- “no sidecars” guarantee: directory contains only `.mv2s` file (similar to existing lex test)

### 9.3 Retrieval determinism tests (always-on)
Add `Tests/WaxIntegrationTests/StructuredMemorySearchDeterminismTests.swift`:
- fixture wax file with text+vec+structured evidence
- run `wax.search` twice with identical request inputs (including explicit as-of); assert identical results + ordering + sources
- include at least one case where `.structuredMemory` lane is the reason a frame appears in top-K
- include at least one “no-signal” case: query yields zero entity candidates → structured lane contributes nothing

### 9.4 Lane behavior tests
Add `Tests/WaxIntegrationTests/StructuredMemorySearchTests.swift`:
- ingest known fact with evidence pointing to a frame that would not otherwise match strongly
- query via `wax.search`; expect that frame appears in top-K via `.structuredMemory` source

### 9.5 MemoryOrchestrator pipeline + recipe tests (new)
Add `Tests/WaxIntegrationTests/MemoryOrchestratorIngestionPipelineTests.swift`:
- determinism across concurrency settings: same input + budgets yields identical results and stable report counts
- budget truncation: max chunks / max facts per chunk triggers explicit report flags and does not crash
- cancellation: cancel mid-ingest; only fully committed batches are visible; report indicates partial ingest

Add `Tests/WaxIntegrationTests/RAGContextRecipeTests.swift`:
- lane ordering + tie-breaks are deterministic
- per-lane budgets are respected (including fact-card rendering)
- token counting remains stable (fact cards treated as plain text)

---

## 10) Performance / Maintenance

### 10.1 Compaction
- Existing `FTS5SearchEngine.serialize(compact: true)` runs `VACUUM`, which compacts the entire SQLite DB (including structured memory tables). This is sufficient for v1.
- Add an explicit orchestrator maintenance hook if needed:
  - `MemoryOrchestrator.compactIndexes(...)` already exists and will cover structured memory automatically under Option A.

### 10.2 Budgets and truncation
- All traversal/query APIs must enforce:
  - max results
  - max edges visited
  - max depth
  - stable “truncated” flag in the response when budgets are hit

### 10.3 Blob size guardrail
- Add a preflight check before staging:
  - if serialized lex blob size > `Constants.maxBlobBytes`, return a clear error suggesting compaction or (future) Option B.

### 10.4 Orchestrator maintenance hooks (recommended)
We already expose explicit maintenance entrypoints (`optimizeSurrogates`, `compactIndexes`). For best on-device RAG, add *policy-driven hooks* so maintenance can be:
- incremental (small work per ingest) instead of spiky periodic work
- budgeted (max frames / max wall time)
- safe (never violates single-writer constraints)

Hook points (v1):
- `afterRemember`:
  - optional surrogate refresh for newly ingested chunks (bounded)
  - optional compaction when size thresholds are exceeded (rare)
- `onOpen` / `prewarm`:
  - optional tokenizer warmup + embedder warmup (already modeled by `WaxPrewarm`)

Do not run expensive maintenance implicitly during reads/recall.

---

## 11) Milestones and Granular TODOs

### Milestone 0 — Semantics Lock + Architecture Sign-off (0.5–2 days)
- Milestone 0 sign-off (filled):
  - Architecture: Option A (extend existing lex SQLite blob)
  - Rollout: always-on (no feature flags / no opt-in)
  - Time semantics: half-open intervals + `StructuredMemoryAsOf` (system+valid)
  - Search as-of: `SearchRequest.asOfMs` default `Int64.max` (“latest”, never wall-clock)
  - Redaction: v1 non-goal (explicitly not supported)
  - Evidence dedupe: v1 read-time grouping (no UNIQUE constraint)
  - FK enforcement: required (`PRAGMA foreign_keys=ON`)
  - Hashing: SHA-256 (CryptoKit), canonical encoding rules locked in §3
  - Span identity: `span_key_hash` excludes mutable fields; retraction sets `system_to_ms`

- [ ] Decide Option A vs Option B for v1 (default: Option A).
- [ ] Confirm compliance redaction stance for v1: **not supported** (explicit non-goal).
- [ ] Freeze time semantics: half-open intervals; explicit `StructuredMemoryAsOf` (system+valid).
- [ ] Freeze dedupe policy:
  - [ ] entity dedupe by `EntityKey`
  - [ ] predicate dedupe by `PredicateKey`
  - [ ] fact dedupe by `fact_hash`
  - [ ] evidence dedupe: read-time grouping (no UNIQUE constraint in v1)
- [ ] Write “Determinism Spec” section into this doc:
  - [ ] stable ordering keys for each query
  - [ ] tie-breakers
- [ ] how `asOf` participates in filters (system + valid visibility)
- [ ] Freeze canonicalization + hashing:
  - [ ] SHA-256 implementation choice (CryptoKit) and exact encoding rules
  - [ ] alias normalization rules (`alias_norm`)
- [ ] Decide span mutability model:
  - [ ] retraction updates `system_to_ms` on open span
  - [ ] `span_key_hash` excludes mutable fields and remains stable
- [ ] Decide FK enforcement stance:
  - [ ] `PRAGMA foreign_keys=ON` required and tested (recommended), or remove FK clauses from schema
- [ ] Identify API compatibility constraints:
  - [ ] integrate structured memory into `Wax.search` always-on (deterministic; budgeted; explicit as-of)
  - [ ] keep `FTS5SearchEngine` name public (or explicitly version bump)
  - [ ] decide whether `OrchestratorConfig.enableTextSearch` becomes `enableLexIndex` (recommended) and whether lex indexing is always-on for RAG.

Deliverable:
- [ ] Updated `proposals/Wax-Structured-Memory-Implementation-Plan.md` with final decisions.

### Milestone 1 — Tests First (2–4 days)
- [ ] Add failing schema/migration tests:
  - [ ] `user_version` upgrade 1 -> 2
  - [ ] legacy `application_id=0/user_version=0` upgrade to 2
- [ ] Add failing structured memory CRUD + determinism tests (in-memory engine).
- [ ] Add failing Wax-file persistence tests (commit + reopen).

Deliverable:
- [ ] New tests committed and failing only due to missing implementation.

### Milestone 2 — Schema + Engine Implementation (3–7 days)
- [ ] Extend `Sources/WaxTextSearch/FTS5Schema.swift` to `userVersion = 2` and implement migration.
- [ ] Add new schema creation helpers in `WaxTextSearch` (structured memory DDL + indexes).
- [ ] Refactor `Sources/WaxTextSearch/FTS5SearchEngine.swift`:
  - [ ] keep single `DatabaseQueue`
  - [ ] add structured memory buffered ops + flush in transactions
  - [ ] implement structured memory CRUD/query APIs called by tests
  - [ ] ensure `serialize()/deserialize()` includes new tables
- [ ] Ensure `TextSearchEngineTests` updated for `user_version == 2` expectations.

Gate:
- [ ] All Milestone 1 tests pass.

### Milestone 3 — Wax-facing Session APIs (1–3 days)
- [ ] Add `Sources/Wax/StructuredMemorySession.swift` (or extend `WaxTextSearchSession`).
- [ ] Add `public extension Wax { func structuredMemory() async throws -> WaxStructuredMemorySession }`.
- [ ] Ensure session lifecycle stages lex index correctly (no regression with vector commit invariant).

Gate:
- [ ] End-to-end Wax persistence tests pass.

### Milestone 4 — Retrieval Integration (always-on) (2–5 days)
- [ ] Add as-of to `Sources/Wax/UnifiedSearch/SearchRequest.swift` (`asOfMs: Int64 = Int64.max`, meaning “latest”; no wall-clock default).
- [ ] Add `StructuredMemorySearchOptions` to `Sources/Wax/UnifiedSearch/SearchRequest.swift` (non-optional with a default value).
- [ ] Implement structured-memory candidate lane in `Sources/Wax/UnifiedSearch/UnifiedSearch.swift`:
  - [ ] alias match → entity candidates
  - [ ] fact query → evidence frames
  - [ ] deterministic ranking of evidence frames
  - [ ] include in RRF fusion with stable ordering
  - [ ] add `.structuredMemory` to `SearchResponse.Source`
- [ ] Add determinism tests for always-on lane.

Gate:
- [ ] All determinism tests pass.

### Milestone 5 — Ingestion Extractor + Orchestrator Hook (timeboxed 2–6 days)
- [ ] Add deterministic `StructuredMemoryExtractor` protocol + reference extractor.
- [ ] Add `StructuredMemoryIngestionConfig` + `MemoryOrchestratorBudgets` + `MemoryIngestionReport` to orchestrator config / return types.
- [ ] Refactor `Sources/Wax/Orchestrator/MemoryOrchestrator.swift` into staged phases (see §8.4):
  - [ ] plan → chunk → prepare(concurrent) → commit(ordered/streaming) → finalize
- [ ] Wire extractor into the ingest loop:
  - [ ] compute `nowMs` once per `remember()` call
  - [ ] batch-write structured memory deltas to the lex engine
  - [ ] stage/commit keeps existing invariants
- [ ] Implement bounded parallelism for embedding + extraction with separate limits (no unbounded task creation).
- [ ] Implement ordered/streaming commit with a bounded reorder buffer (`maxPreparedBatchesInFlight`).
- [ ] Return `MemoryIngestionReport` from `remember(...)` and test report determinism (excluding durations).
- [ ] Add explicit maintenance hook (`maintainIfNeeded(policy:)`) for compaction/VACUUM and blob-size guardrails.
- [ ] Add tests that ingest content and later query structured memory through session APIs, including ingestion report/truncation behavior.

Gate:
- [ ] Deterministic tests only; no LLM in core test paths.

### Milestone 5.1 — Context recipe API (1–3 days)
- [ ] Add `RAGContextRecipe` with lane configs + default recipes.
- [ ] Wire recipes through `MemoryOrchestrator.recall(...)` into `FastRAGContextBuilder` (or a thin wrapper) without breaking existing call-sites.
- [ ] Add deterministic recipe tests (lane ordering + budgets + fact-card rendering).

### Milestone 6 — Polish (ongoing)
- [ ] Doc comments for all public types.
- [ ] Add `TRACE`-level logging hooks for “why did this fact appear”.
- [ ] Add basic perf tests (optional) focusing on:
  - [ ] worst-case traversal budgets
  - [ ] serialize/deserialize time for lex DB under moderate size

---

## 12) Agent Work Packets (copy/paste prompts)

### Packet A: Schema + migrations
Prompt:
Implement the SQLite schema + migration (user_version 1 -> 2) for structured memory inside the existing lex SQLite DB used by `FTS5SearchEngine`. Keep migrations deterministic and idempotent. Update/extend tests as needed.

Goal:
All schema/migration tests pass, legacy blobs are upgraded in-memory, and serialized blobs report correct `application_id` + `user_version`.

Task Breakdown:
- Add structured memory DDL + required indexes to `FTS5Schema` migration path.
- Ensure `validateOrUpgrade` upgrades legacy (0/0) and v1 (1) to v2.
- Add/adjust Swift Testing cases verifying PRAGMAs and table presence.

### Packet B: Engine implementation (actor, batching, determinism)
Prompt:
Extend `FTS5SearchEngine` so it is the single writer/serializer for the lex SQLite DB and also supports structured memory CRUD + queries with explicit `StructuredMemoryAsOf` and budgets. Must be deterministic and avoid unbounded allocations.

Goal:
Structured memory contract tests pass; `serialize/deserialize` round-trips preserve structured memory; flush behavior remains correct.

Task Breakdown:
- Add structured memory pending-op buffers and flush them in the same DB transactions.
- Implement entity upsert/alias normalization, fact assert, span close, evidence insert.
- Implement deterministic read queries with stable ordering + truncation flags using `StructuredMemoryAsOf`.

### Packet C: Wax API + sessions
Prompt:
Expose a Wax-facing structured memory session API that composes with existing `WaxTextSearchSession` and keeps the single-writer constraint. Ensure commit/staging behavior remains correct with vector embeddings.

Goal:
End-to-end Wax tests pass; no regressions in existing text/vector workflows.

Task Breakdown:
- Add `structuredMemory()` and a session wrapper that forwards to the shared lex engine.
- Keep API Swifty and hard to misuse (typed keys, explicit `StructuredMemoryAsOf`).

### Packet D: Search integration
Prompt:
Integrate structured memory into `Wax.search` (always-on). Add a deterministic structured-memory candidate lane that surfaces evidence frames and fuses them via RRF. Add `asOfMs` to `SearchRequest` with a deterministic default (`Int64.max`).

Goal:
Determinism tests guarantee stable results and tie-breaks for the always-on structured-memory lane, and `.structuredMemory` is present when evidence causes a hit.

Task Breakdown:
- Add request option + response source.
- Implement alias→entity→facts→evidenceFrames path.
- Add stable ranking/tie-breaks and tests.

### Packet E: MemoryOrchestrator (on-device RAG pipeline)
Prompt:
Refactor `MemoryOrchestrator` into an explicit, deterministic *staged* pipeline (plan → chunk → prepare(concurrent) → commit(ordered/streaming) → finalize) that produces frames/chunks, FTS, vector embeddings, and structured memory (entities/facts/evidence) in a single commit. Add budgets, split parallelism (embedding vs extraction), an ordered/streaming commit with bounded in-flight batches, and a first-class ingestion report suitable for debugging/evals.

Goal:
`remember(...)` remains deterministic and produces structured memory and evidence in the same commit as frames/chunks; ingestion respects budgets and bounded memory; and a stable `MemoryIngestionReport` is returned (deterministic except durations).

Task Breakdown:
- Introduce `MemoryOrchestratorBudgets`, `StructuredMemoryIngestionConfig`, and `MemoryIngestionReport`.
- Implement staged phases per §8.4, including an ordered/streaming commit with a bounded reorder buffer (`maxPreparedBatchesInFlight`).
- Run embedding + structured extraction with bounded parallelism and separate limits (no unbounded tasks).
- Batch lex writes (FTS + structured) via the single-writer `FTS5SearchEngine`.
- Add tests that assert: counts, truncation flags, determinism (two runs identical), and evidence points to committed frame IDs.

Follow-up (separate PR / packet):
- Add recipe-driven `recall(...)` (`RAGContextRecipe`) and policy-driven maintenance hooks (§7.3, §10.4).

---

- Summary:
  - Implement v1 by extending the existing lex SQLite DB blob (no WaxCore file-format changes) and ensuring a single engine owns all writes/serialization.
  - Add structured memory tables (entities, aliases, predicates, facts, spans, evidence) with deterministic time semantics and budgeted queries.
  - Integrate into retrieval + ingestion as always-on, with strong determinism and budget guarantees.
