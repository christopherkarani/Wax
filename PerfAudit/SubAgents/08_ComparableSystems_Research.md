Prompt:
You are a performance researcher. Your job is to extract best practices from comparable production/open-source RAG memory systems and on-device vector+text search stacks, then translate them into concrete actions for Wax.

Goal:
Produce a concise research brief with:
- comparable architectures
- specific best practices relevant to Wax
- which practices are compatible with Apple on-device constraints
- citations/links

Task BreakDown:
1) Identify comparables (must include MemVid)
   - MemVid (repo + docs + any perf claims/benchmarks)
   - At least 2 more: e.g., FAISS (CPU/GPU), sqlite FTS5 best practices, llama.cpp retrieval integrations, or other on-device vector store implementations.

2) Extract concrete best practices
   - Indexing strategies: HNSW tuning, quantization, sharding, delta indexes, background merges.
   - Storage: append-only segments, compaction, checksums, memory mapping, IO batching.
   - Query pipelines: hybrid ranking/fusion, caching, batching, token-budget enforcement.

3) Translate into Wax actions
   - For each practice: map to Wax subsystem + files likely to change + expected performance win.
   - Flag incompatibilities with Apple platforms (memory, power, sandboxed storage, ANE scheduling).

Deliverable:
- A markdown brief with bulletproof citations and a table mapping best practices -> Wax actions.
