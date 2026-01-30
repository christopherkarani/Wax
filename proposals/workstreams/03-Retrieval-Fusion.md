Prompt:
Design the hybrid retrieval and fusion layer that combines vector search, keyword search, graph traversal, and temporal ranking.

Goal:
A deterministic, scalable retrieval pipeline that improves precision without harming existing behavior.

Task BreakDown:
- Define `HybridQuery`, `GraphHints`, and `HybridHit` structures.
- Specify graph traversal strategies (depth limits, relation filters, max fan-out).
- Define fusion scoring: weighted RRF with recency/validity/confidence adjustments.
- Explain how to integrate with `UnifiedSearch` and `FastRAGContextBuilder`.
- Identify fallback behaviors when graph/fact stores are empty or disabled.

