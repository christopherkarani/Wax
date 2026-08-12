# Architecture

Understand the module dependency graph, actor model, and end-to-end data flow.

## Overview

Wax is organized as a stack of Swift Package Manager library targets. Each layer adds capability while depending only on the layers below it.

> Note: ``Memory`` is the public facade. `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, and `WaxSession` are package-only internals — they are documented here for contributors and are not callable from outside the Wax package.

## Module Dependency Graph

```
┌─────────────────────────────────────────┐
│                 Wax                     │  Orchestration, RAG, Unified Search
│  MemoryOrchestrator, PhotoRAG, VideoRAG │
└────────────┬──────────┬────────────┬────┘
             │          │            │
     ┌───────▼──┐  ┌────▼────────┐  │
     │WaxText   │  │WaxVector    │  │
     │Search    │  │Search       │  │
     │(FTS5/SQL)│  │(Accelerate/ │  │
     │          │  │ MetalANNS)  │  │
     └────┬─────┘  └──────┬──────┘  │
          │               │         │
          │  ┌────────────▼──────┐  │
          │  │WaxVectorSearch    │  │  (trait-gated)
          │  │MiniLM             │  │
          │  │(CoreML embedder)  │  │
          │  └───────────────────┘  │
          │                         │
     ┌────▼─────────────────────────▼────┐
     │             WaxCore               │  Persistence, WAL, Binary Codec,
     │  Wax actor, .wax format, Locks   │  Structured Memory types
     └───────────────────────────────────┘
```

## Actor Model

Every major subsystem is an actor with its own serial executor:

| Actor | Access | Responsibility |
|-------|--------|---------------|
| ``Memory`` | **public** | Facade: save/search/delete/flush/close, stats, diagnostics |
| `MemoryOrchestrator` | package | Text ingestion, recall, session management |
| `PhotoRAGOrchestrator` | package | Photo library sync, OCR, photo queries |
| `VideoRAGOrchestrator` | package | Video ingestion, transcript handling, segment queries |
| `WaxSession` | package | Frame writes, search delegation, structured memory |
| `Wax` (WaxCore) | package | File I/O, WAL, frame storage, writer leasing |
| `FTS5SearchEngine` | package | BM25 indexing/search, structured memory persistence |
| `AccelerateVectorEngine` | package | CPU vector index (default below 10,000 vectors) |
| `MetalANNSVectorEngine` | package | GPU vector index (auto-activates at 10,000+ vectors) |
| `MiniLMEmbedder` | package | CoreML inference |

### Actor Boundaries

Each actor maintains its own mutable state. Communication between actors happens exclusively through `async` method calls, with `Sendable` types crossing boundaries.

## End-to-End Data Flow

### Ingestion (remember)

```
User text
  │
  ▼
MemoryOrchestrator.remember()
  │
  ├─ Chunk text (ChunkingStrategy)
  │
  ├─ Embed chunks (EmbeddingProvider.embed(batch:))
  │
  ├─ Frame payload write ──► WAL
  │
  ├─ FTS5SearchEngine.index() ──► SQLite FTS5
  │
  ├─ VectorEngine.add() ──► Flat vector / MetalANNS index (pending)
  │
  └─ Writes land in the WAL; WaxSession.commit() (via flush()/close())
     persists them ──► TOC + Footer + Header
```

### Retrieval (recall)

```
User query
  │
  ▼
MemoryOrchestrator.recall()
  │
  ├─ Embed query (if vector search enabled)
  │
  ▼
FastRAGContextBuilder.build()
  │
  ├─ SearchRequest (unified search)
  │   ├─ BM25 lane (FTS5SearchEngine.search())
  │   ├─ Vector lane (VectorEngine.search())
  │   ├─ Structured memory lane (entity/fact queries)
  │   └─ Timeline lane (reverse chronological fallback)
  │
  ├─ RRF fusion (AdaptiveFusionConfig per QueryType)
  │
  ├─ Intent-aware reranking
  │
  ├─ Token budget assembly
  │   ├─ Expansion (first result, up to expansionMaxTokens)
  │   ├─ Surrogates (tier-selected: full/gist/micro)
  │   └─ Snippets (remaining budget)
  │
  └─ RAGContext (items + totalTokens)
```

## Read/Write Multiplexing

``WaxSession`` abstracts the difference between read-only and read-write access:

- **Read-only sessions** can search and read frames concurrently
- **Read-write sessions** acquire a writer lease from the underlying `Wax` actor

Multiple read-only sessions can operate simultaneously. Only one read-write session can be active at a time, controlled by the ``WaxSession/WriterPolicy``.

## Persistence Model

All data flows through the `.wax` file:

1. **Frame payloads** are written to the WAL first (crash-safe)
2. **Text indexes** are serialized as SQLite blobs stored in the TOC's segment catalog
3. **Vector indexes** are serialized in the MV2V format stored in the TOC's segment catalog
4. A **commit** flushes the WAL, writes the updated TOC and footer, and updates the header

This single-file design makes backups, transfers, and atomic operations straightforward.
