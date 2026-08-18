# Wax

On-device memory for agents and apps: persist text (and experimental photo/video), then retrieve ranked context.

## Language

**RetrievalMode**:
How a query is retrieved from Memory: text-only, vector-only, or hybrid. Hybrid may fall back to text; vector-only must not.
_Avoid_: EmbeddingPolicy, QueryEmbeddingPolicy, DirectSearchMode, SearchMode (as the name hosts use)
