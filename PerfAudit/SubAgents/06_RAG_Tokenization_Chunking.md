Prompt:
You are a Swift concurrency + performance engineer. Audit Wax's end-to-end RAG context building path for avoidable work (actor hops, tokenization passes, string/data copies) and propose step-function improvements.

Goal:
Identify the dominant CPU time + allocation sources in RAG recall (search -> preview loads -> token counting/truncation -> context assembly) and propose a concrete fix list.

Task BreakDown:
1) Read implementation
   - `Sources/Wax/RAG/FastRAGContextBuilder.swift`
   - `Sources/Wax/RAG/TokenCounter.swift`
   - `Sources/Wax/UnifiedSearch/UnifiedSearch.swift` (hybrid search execution + metadata/preview fetching)
   - `Sources/Wax/Orchestrator/MemoryOrchestrator.swift` (recall path)
   - Chunking: `Sources/Wax/**/TextChunker*` and any tokenizer dependencies

2) Identify bottlenecks
   - Tokenization:
     - cache hit rates; unnecessary encode/decode; repeated `String` allocations.
     - batch APIs: where they help, where they create too many tasks.
   - Actor hops:
     - `Wax.search` internal calls (`frameMetasIncludingPending`, `framePreviews`, `frameContentIncludingPending`).
     - any TaskGroup churn or redundant async boundaries.
   - Context assembly:
     - preview UTF-8 decoding; truncation passes; any double-work between snippet and expansion.

3) Propose improvements
   - Must include at least one architectural change that yields a step-function win:
     - e.g., token-aware preview generation at ingest, precomputed snippet windows, or storing pre-tokenized representations for the encoding used.
   - Include micro-optimizations separately.

4) Benchmark gaps
   - Propose benchmarks to isolate:
     - wax.search alone
     - preview loading
     - token counting/truncation
     - context builder end-to-end under concurrency (N parallel recall queries)

Deliverable:
- Markdown write-up with ranked bottlenecks + fixes + benchmark additions.
