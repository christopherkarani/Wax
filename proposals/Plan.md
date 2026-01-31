# Wax KG + Fact Store Plan

## Context
Wax currently supports hybrid text/vector/timeline search but lacks structured fact memory and graph traversal. This plan introduces a typed fact store with provenance and a lightweight knowledge graph, integrated into hybrid retrieval. The goal is correctness-first memory with temporal truth, auditability, and predictable performance.

## Objectives
- Add a typed, versioned fact store.
- Add a knowledge graph for entity-centric retrieval.
- Integrate graph + fact signals into retrieval fusion.
- Preserve existing search behavior and performance.

## Workstreams
1) Data Model + Public APIs
2) Storage Backend + Indexes
3) Retrieval Fusion + RAG Integration
4) Ingestion + Conflict Resolution
5) Maintenance + Evaluation

## Detailed Steps

### 1) Data Model + Public APIs
- Define `EntityID`, `FactID`, `EdgeID` value types.
- Define `Entity`, `Relation`, `Fact`, `FactValue`, `Provenance`.
- Add `GraphStore` and `FactStore` protocols with async APIs.
- Add `HybridQuery`, `GraphHints`, `HybridHit` types.

### 2) Storage Backend + Indexes (SQLite)
- Create schema: `entities`, `entity_aliases`, `relations`, `facts`, `provenance`.
- Add indexes for common lookup paths.
- Implement SQLite-backed `GraphStore` + `FactStore` actors.
- Ensure serialization is deterministic and uses Codable.

### 3) Retrieval Fusion + RAG Integration
- Add graph traversal lane with bounded depth.
- Add fact lookup lane (predicate or entity based).
- Fuse results with existing vector + text via weighted RRF.
- Add scoring weights for recency, validity, confidence.
- Extend `FastRAGContextBuilder` to accept hybrid hits.

### 4) Ingestion + Conflict Resolution
- Add extractor interface for entity/fact extraction (LLM or rules).
- On ingest, write raw frame + extracted facts/graph edges.
- Add conflict resolution rules: supersede vs add, with validity windows.

### 5) Maintenance + Evaluation
- Nightly consolidation (merge aliases, prune duplicates).
- Weekly summarization (derived summaries; no loss of provenance).
- Monthly reindex (refresh embeddings, reweight graph edges).
- Add eval harness for contradiction resolution and temporal queries.

## Dependencies / Assumptions
- Existing `Wax` stores remain canonical for raw content.
- Embedding store and text search remain unchanged in v1.
- Graph/fact store can be stored in SQLite sidecar.

## Deliverables
- Proposal doc: `proposals/Wax-KG-Memory-Proposal.md`
- Workstream prompt packets in `proposals/workstreams/`

