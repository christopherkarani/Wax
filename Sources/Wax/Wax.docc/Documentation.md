# ``Wax``

High-level orchestration and RAG for persistent, on-device memory with semantic search.

## Overview

The Wax module is the primary public API surface for building memory-augmented applications. It provides:

- **``MemoryOrchestrator``** — The main text RAG orchestrator: ingest text, recall context, manage sessions
- **``PhotoRAGOrchestrator``** — Multimodal RAG for photo libraries with OCR and CLIP embeddings
- **``VideoRAGOrchestrator``** — Video segment RAG with transcript integration
- **``WaxSession``** — Unified frame, search, and structured memory interface with read/write multiplexing
- **Unified search** — BM25 + vector + structured memory fusion with reciprocal rank fusion (RRF)
- **RAG pipeline** — Token-budget-aware context assembly with surrogate tiers and intent-aware reranking

```swift
import Wax

// Create an orchestrator with on-device embeddings
let embedder = try MiniLMEmbedder()
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: .init(),
    embedder: embedder
)

// Remember content
try await orchestrator.remember("Met with Alice about the Q4 roadmap")

// Recall relevant context
let context = try await orchestrator.recall(query: "What did Alice say?")
print(context.items.map(\.text))
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Architecture>

### Orchestration

- <doc:MemoryOrchestrator>
- ``MemoryOrchestrator``
- ``OrchestratorConfig``

### Sessions

- <doc:SessionManagement>
- ``WaxSession``

### RAG Pipeline

- <doc:RAGPipeline>
- ``FastRAGContextBuilder``
- ``FastRAGConfig``
- ``RAGContext``

### Search

- <doc:UnifiedSearch>
- ``SearchRequest``
- ``SearchResponse``
- ``SearchMode``

### Photo RAG

- <doc:PhotoRAG>
- ``PhotoRAGOrchestrator``
- ``PhotoRAGConfig``

### Video RAG

- <doc:VideoRAG>
- ``VideoRAGOrchestrator``
- ``VideoRAGConfig``
