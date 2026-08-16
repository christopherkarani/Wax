---
name: wax-memory-maintenance
description: Maintain the Wax memory store used by the Hermes wax-memory provider.
---

# Wax Memory Maintenance

Use when the active Hermes memory provider is `wax-memory`.

## Checks

1. Confirm the broker is reachable: `hermes wax-memory doctor`
2. Prefer `wax_recall` for assembled context and `wax_search` for raw hits
3. Store durable facts with `wax_remember` and `memory_type` from `note`, `task_state`, `user_preference`, `decision`, `lesson`, `handoff`, `constraint`, `fact`
4. Write session continuity with `wax_handoff`; do not dump raw transcripts
5. Use structured tools (`wax_entity_upsert`, `wax_fact_assert`, `wax_facts_query`) only for stable knowledge-graph facts

## Recovery

- If recall is empty, run `npx waxmcp --embedder minilm --transport http`
- If vector search is disabled, rebuild both `wax-cli` and `wax-mcp` with MiniLM/Arctic traits
- After `/reset` or `/resume`, rely on the provider session switch — do not invent a new session id
