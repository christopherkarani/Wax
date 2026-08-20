# Wax

On-device memory for agents and apps: persist text (and experimental photo/video), then retrieve ranked context.

## Language

**RetrievalMode**:
How a query is retrieved from Memory: text-only, vector-only, or hybrid. Hybrid may fall back to text; vector-only must not.
_Avoid_: EmbeddingPolicy, QueryEmbeddingPolicy, DirectSearchMode, SearchMode (as the name hosts use)

**Ranking**:
Plans the text-lane query (AND first, then OR fallback) and orders hits. Owns the published score.
_Avoid_: treating the text engine as the planner; calling AND/OR planning retrieval

**MatchPlan**:
Ranking's text-lane interface: AND MATCH, optional OR MATCH, token count. Empty plan (stopwords only) is no text hits.
_Avoid_: literalMatchQuery; passing the raw user string as MATCH

**Match execute**:
The text-lane execute: run a planned MATCH string and return BM25 hits. Does not re-plan AND/OR.
_Avoid_: query planning in the text engine; calling this RetrievalMode; FTS5SearchEngine.search(query:)

**Recall assembly**:
Builds RAGContext from already-ranked hits (token budget, expansion, surrogates). May reorder for an answer budget. Does not rewrite Ranking's published score.
_Avoid_: treating Memory.search as Ranking’s test surface; broker multi-horizon merge (that is Layered recall)

**Layered recall**:
Broker read path that owns scope/identity resolution, fetches from the virtual session store and/or long-term Memory, merges hits, and applies project/repo filters. Horizon flags (working / episodic / durable) are how it interprets a resolved scope—not a second policy language. Callers pass a structured request after coercing tool args; Layered recall owns what those fields mean. Feeds tools such as recall and layered search. Does not own Ranking's published score, Recall assembly's token packing, MCP payloads, or session rebind/hit recording.
_Avoid_: Broker recall; Horizon recall; treating MCP tool names as the module name; splitting recall scope enums from layered horizon flags; putting AgentBrokerValue parsing inside Layered recall

**Long-term Memory**:
The store the broker keeps across virtual sessions. Distinct from a virtual session store.
_Avoid_: default store, global Memory, durable store (as the store name; durable is a horizon)

**Virtual session store**:
A per-session memory store, distinct from long-term Memory, identified by `session_id`. It is its own store, not a metadata slice of long-term Memory. An omitted `session_id` means no virtual session: lookup does not infer one and does not create one. The same `agent_id` and `run_id` pair reuses the active store; one id is not enough; an ended store is not reused.
_Avoid_: Compat session, MCP session registry, `metadata.session_id` (as the store)
