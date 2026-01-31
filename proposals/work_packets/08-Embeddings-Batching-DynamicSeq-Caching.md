Prompt:
Implement Swift-side batching, dynamic sequence handling, and caching for embedding ingestion and vector indexing in MemoryOrchestrator and related caches.

Goal:
A clear, correct, and performant embedding pipeline that prefers batch inference, preserves ordering, minimizes duplicate work via caching, and keeps vector index state consistent across staged commits.

Task BreakDown:
- Audit `MemoryOrchestrator.prepareEmbeddingsBatchOptimized` for correctness and add explicit batch size policy hooks (configurable max batch, adaptive fallback).
- Ensure batch embedding preserves input order deterministically and handles partial cache hits without re-embedding cached texts.
- Add dynamic sequence handling for pending embeddings (staged vs committed) to avoid double-apply in `UnifiedSearchEngineCache`.
- Tighten cache key construction (identity/model/dims/normalized) and ensure cache writes occur after normalization.
- Add doc comments and public API notes on batching behavior and cache semantics.
