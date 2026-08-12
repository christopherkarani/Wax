# Constraints, Quirks, and Limits

## Offline-Only and Single-File Persistence
- Wax is on-device and makes no network calls. Source: `README.md`.
- A single `.wax` file stores data, indexes, metadata, and WAL. Source: `README.md`.
- Wax is not a cloud sync service. Source: `README.md`.

## Public API Surface
- The public Swift API is the `Memory` facade (`import Wax`). `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `WaxSession`, and the `Wax` actor are package-only internals. Source: `Sources/Wax/Memory.swift`.
- Structured memory (entities/facts) and photo/video memory are exposed to agents via the Wax MCP server tools, not via `import Wax`. Source: `README.md`.

## Vector Search and Embeddings
- Built-in embedders (MiniLM, Arctic) require iOS 18/macOS 15+ and their package traits (`MiniLMEmbeddings` on by default, `ArcticEmbeddings` opt-in). Source: `Sources/Wax/BuiltInEmbeddings.swift`.
- `Memory(at:)` auto-wires the built-in MiniLM embedder when vector search is enabled and the platform supports it; otherwise the store runs text-only. Source: `Sources/Wax/Memory.swift`.
- On a fresh store with vector search enabled but no embedder, vector search is auto-disabled (text-only); `memory.stats().vectorSearchEnabled` reports the effective state. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.
- `RetrievalMode.hybrid` (default) falls back to the text lane when the vector lane is unavailable; `RetrievalMode.vectorOnly` throws. `RAGContext.diagnostics` reports requested vs. effective mode. Source: `Sources/Wax/Memory.swift`.
- If query embedding times out, a circuit breaker pauses query embedding for a cooldown (default 60s), then half-opens and retries; a success closes it. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.
- The Metal HNSW vector engine activates automatically at 10,000+ vectors; smaller indexes use an exact Accelerate/CPU flat index. Source: `Sources/WaxVectorSearch/LoadedVectorSearchEngine.swift`.

## Video RAG Constraints (package-only pipeline)
- Video RAG requires host-supplied transcripts; Wax does not transcribe in v1. Source: `README.md`, `Sources/Wax/VideoRAG/VideoRAGProtocols.swift`.
- Video RAG stores text and metadata only; it does not store video/audio clip bytes. Source: `README.md`.
- The video pipeline requires normalized embeddings when `vectorEnginePreference != .cpuOnly` (Metal-backed search). Source: `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`.
- Photos sync is offline-only; iCloud-only assets are indexed as metadata-only and marked degraded. Source: `README.md`.

## Determinism and Token Budgets
- Deterministic retrieval and strict token budgets (cl100k_base) are documented. Source: `README.md`.

## Persistence Lifecycle
- `Memory.save(...)` writes to the WAL; `Memory.flush()` commits pending writes to durable storage; `Memory.close()` flushes and closes. Source: `Sources/Wax/Memory.swift`.
- `Memory.delete(frameID:)` soft-deletes the frame and removes it from the text and vector indexes, committed immediately. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.
