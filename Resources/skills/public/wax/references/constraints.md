# Constraints, Quirks, and Limits

## Offline-Only and Single-File Persistence
- Wax is on-device and makes no network calls. Source: `README.md`.
- A single `.wax` file stores data, indexes, metadata, and WAL. Source: `README.md`.
- Wax is not a cloud sync service. Source: `README.md`.

## Public Memory Facade
- External package snippets should use `Memory`, not package-internal orchestrator/session/search request types.
- If no embedding provider is supplied, set `Memory.Config.enableVectorSearch = false` for first-run text-only stores.
- For hybrid search, open `Memory` with a public `EmbeddingProvider`.
- `Memory.close()` commits and releases resources.

## Package-Internal Types
- `MemoryOrchestrator`, `OrchestratorConfig`, `QueryEmbeddingPolicy`, `WaxSession`, `SearchRequest`, `MiniLMEmbedder`, `PhotoRAGOrchestrator`, and `VideoRAGOrchestrator` are package-internal in the current Wax target.
- These types can be discussed for Wax contributor work, but public docs and skills must label them as package-internal.

## Video and Photo RAG Constraints
- Video RAG and Photo RAG orchestrators are package-internal today.
- Video RAG requires host-supplied transcripts; Wax does not transcribe in v1. Source: `README.md`, `Sources/Wax/VideoRAG/VideoRAGProtocols.swift`.
- Video RAG stores text and metadata only; it does not store video/audio clip bytes. Source: `README.md`.

## Determinism and Token Budgets
- Deterministic retrieval and strict token budgets are documented. Source: `README.md`.
