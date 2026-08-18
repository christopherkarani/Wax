# Wax MCP project rules

Paste **AGENTS.md** after installing the Wax MCP server. For Hermes or
OpenClaw, append the **SOUL.md** stanza — do not replace the rest of the soul.

The inner `text` fences are what you copy. Keep them in lockstep with
`WaxMCPAgentPlaybook` in `Sources/WaxCLI/WaxCLICommand.swift` and the README
Agent Quick Start details.

## AGENTS.md / CLAUDE.md / Cursor rules

```text
Wax is the shared memory layer. Chat dies; Wax does not. Skip one-line Q&A. Use on any multi-step coding, debug, or research task.

Open every multi-step session:
1. Call `handoff_latest` first (`project` = repo name). Read it. Do not ask the user to restate it.
2. Call `session_start` once. Keep `session_id`. Do not invent one. Pass stable `agent_id` and `run_id` so a retry reuses the same session.
3. Call `recall` without `session_id` for durable-only. `recall` with `session_id` merges that session with durable long-term memory.

Workflow rules:
- Use `remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `recall` for assembled context and `search` for raw ranked hits.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores.
- Use `handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `session_end`.
- Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
- Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.


Tactical (this task) — write immediately, not at the end:
- `remember` with top-level `session_id`, `memory_type: task_state`, `durability: working`
- When: you lock a plan, a path fails (what + why), you find a landmine / owner file / required gate, a milestone finishes, or you are about to spawn a subagent / compact / stop
- Read with `recall` plus `session_id`

Strategic (survives this session):
- `remember` without `session_id`, `durability: durable`, `memory_type` one of `decision` | `lesson` | `constraint` | `user_preference` | `fact`
- When: the user corrects you, you make an architecture or product decision, a pitfall will waste the next agent time, a standing preference appears, or a repo fact is stable

Both horizons on a long task: `compact_context`.
`recall` with `session_id` merges that session with durable long-term memory. `search` with `session_id` is session-store only.

Share across agents: the parent writes before spawning. Children often have no Wax tools. The parent writes again from their evidence.

Close: `handoff` (`content`, `project`, `pending_tasks`, `session_id`) then `session_end`.

Do not put `session_id` in `metadata`. Do not store secrets, transcripts, or huge logs. Do not manage `SESSION_STORE`, `--store-path`, or `flush`. Prefer `mode: "text"` for exact names and recent facts. Structured `entity_*` / `fact_*` tools are for stable graph facts, not debug notes.
```

## Hermes / OpenClaw SOUL.md

SOUL.md is identity. Append this section. Do not turn the whole soul into a tool manual.

```text
## Memory (Wax)

You have Wax. Chat is not memory.

On every multi-step task: `handoff_latest` → `session_start` → keep `session_id`.

Write as you go:
- This task: `remember` with `session_id`, `memory_type: task_state`, `durability: working` (plan, failed path, landmine, milestone, before you stop or spawn another agent).
- Long-term: `remember` without `session_id`, `durability: durable`, type `decision` / `lesson` / `constraint` / `user_preference` / `fact` (corrections, decisions, standing prefs, stable repo facts).

Read: `recall` without `session_id` for durable-only. `recall` with `session_id` merges this session with durable memory. Need a budgeted mix → `compact_context`.

Close with `handoff` then `session_end`. Do not invent a `session_id` or put it in `metadata`. Do not store secrets.
```
