# Wax

On-device memory for agents and apps: persist text (and experimental photo/video), then retrieve ranked context.

## Language

**RetrievalMode**:
How a query is retrieved from Memory: text-only, vector-only, or hybrid. Hybrid may fall back to text; vector-only must not.
_Avoid_: EmbeddingPolicy, QueryEmbeddingPolicy, DirectSearchMode, SearchMode (as the name hosts use)

**Ranking**:
Plans the text-lane query (AND first, then OR fallback) and orders hits. Owns the published score.
_Avoid_: treating the text engine as the planner; calling AND/OR planning retrieval

**Match execute**:
The text-lane execute: run a planned MATCH string and return BM25 hits. Does not re-plan AND/OR.
_Avoid_: query planning in the text engine; calling this RetrievalMode

**Recall assembly**:
Builds RAGContext from already-ranked hits (token budget, expansion, surrogates). May apply a later answer-focused rerank. Not Ranking.
_Avoid_: treating Memory.search as Ranking’s test surface
