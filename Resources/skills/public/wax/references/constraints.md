# Constraints, Quirks, and Limits

## Offline-Only and Single-File Persistence
- Wax is on-device and makes no network calls. Source: `README.md`.
- A single `.wax` file stores data, indexes, metadata, and WAL. Source: `README.md`.
- Wax is not a cloud sync service. Source: `README.md`.

## Vector Search and Embeddings
- `MemoryOrchestrator` initialization throws if `enableVectorSearch == true`, `embedder == nil`, and there is no committed vector index. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.
- `QueryEmbeddingPolicy.always` throws when vector search is disabled or no embedder is configured. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.
- `MemoryOrchestrator` and `VideoRAGOrchestrator` L2-normalize embeddings when `embedder.normalize == true`. Sources: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`, `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`.
- `OrchestratorConfig.useMetalVectorSearch` is a preference; actual engine selection checks Metal availability at runtime. Source: `Sources/Wax/Orchestrator/OrchestratorConfig.swift`.

## Video RAG Constraints
- Video RAG requires host-supplied transcripts; Wax does not transcribe in v1. Source: `README.md`, `Sources/Wax/VideoRAG/VideoRAGProtocols.swift`.
- Video RAG stores text and metadata only; it does not store video/audio clip bytes. Source: `README.md`.
- `VideoRAGOrchestrator` requires normalized embeddings when `vectorEnginePreference != .cpuOnly` (Metal-backed search). Source: `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`.
- File ingestion requires file URLs and existing files. Source: `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`.
- Photos sync is offline-only; iCloud-only assets are indexed as metadata-only and marked degraded. Source: `README.md`.

## Determinism and Token Budgets
- Deterministic retrieval and strict token budgets (cl100k_base) are documented. Source: `README.md`.

## Persistence Lifecycle
- `MemoryOrchestrator.flush()` commits; `close()` commits, closes the session, and closes the store. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.
- `VideoRAGOrchestrator.ingest(...)` commits and rebuilds the index; `flush()` commits. Source: `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`.
