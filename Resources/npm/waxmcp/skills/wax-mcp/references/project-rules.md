# Wax MCP project rules

Paste this block into `CLAUDE.md`, an app-level `AGENTS.md`, Cursor rules, or any host
always-on instruction file after installing the Wax MCP server.

Keep this paste block aligned with the MCP server playbook SoT:
`Sources/WaxMCPServer/AgentInstructions.swift`. Do not fork a conflicting essay.
Do not replace the Wax repo root `AGENTS.md` (contributor hygiene) with this block.

Intended primary read path: `recall`. For raw `search`, prefer `mode: "hybrid"` unless
a lexical text lookup is requested (code default alignment is Phase 4 / #94).

```text
Use the Wax MCP server for persistent memory in this repo.

Workflow rules:
- At session start, call `handoff_latest` first to load prior context, then call `session_start` once and keep the returned `session_id`.
- Use `remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `recall` for assembled context (preferred read path) and `search` for raw ranked hits.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores.
- Use `handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `session_end`.
- Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
- Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.

Behavior expectations:
- Read existing handoffs and recall results before asking me to restate prior context.
- Keep memory writes concise, factual, and scoped to the task.
- When a cross-session result looks relevant, cite the provenance metadata so we know which session store it came from.
```
