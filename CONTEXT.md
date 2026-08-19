# Wax

On-device memory for agents and apps: persist text (and experimental photo/video), then retrieve ranked context.

## Language

**RetrievalMode**:
How a query is retrieved from Memory: text-only, vector-only, or hybrid. Hybrid may fall back to text; vector-only must not.
_Avoid_: EmbeddingPolicy, QueryEmbeddingPolicy, DirectSearchMode, SearchMode (as the name hosts use)

**Long-term Memory**:
The store the broker keeps across virtual sessions. Distinct from a virtual session store.
_Avoid_: default store, global Memory, durable store (as the store name; durable is a horizon)

**Virtual session store**:
A per-session memory store, distinct from long-term Memory, identified by `session_id`. It is its own store, not a metadata slice of long-term Memory. An omitted `session_id` means no virtual session: lookup does not infer one and does not create one. The same `agent_id` and `run_id` pair reuses the active store; one id is not enough; an ended store is not reused.
_Avoid_: Compat session, MCP session registry, `metadata.session_id` (as the store)
