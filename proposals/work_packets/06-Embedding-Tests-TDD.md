Prompt:
Define the failing test matrix for embedding batching, dynamic batch sizing, and caching in the MiniLM/CoreML path and the MemoryOrchestrator ingest pipeline. Use Swift Testing only and keep tests deterministic.

Goal:
A complete failing test suite that locks down batch vs sequential equivalence, cache hit behavior, ordering guarantees, and error handling for embedding ingestion before any implementation changes.

Task BreakDown:
- Add Swift Testing fixtures for EmbeddingProvider and BatchEmbeddingProvider fakes (deterministic vectors, controllable latency, deterministic ordering).
- Add MemoryOrchestrator ingest tests that verify: batch path is used when available, output order matches input order, and embeddings are normalized exactly once.
- Add EmbeddingMemoizer tests for hit/miss accounting, eviction order, and identity-sensitive keys (provider/model/dims/normalized).
- Add CoreML bundle tests that assert missing .mlmodelc resource produces a clear, stable error (no flakiness).
- Add regression tests for pending embedding sequence handling in UnifiedSearchEngineCache (cache reuse + incremental apply).
