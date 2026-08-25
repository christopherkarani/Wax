# Wax MCP project rules

Paste **AGENTS.md** after installing the Wax MCP server. For Hermes or
OpenClaw, append the **SOUL.md** stanza — do not replace the rest of the soul.

The inner `text` fences are what you copy. Keep them in lockstep with
`WaxMCPAgentPlaybook` in `Sources/WaxCLI/WaxCLICommand.swift` and the README
Agent Quick Start details.

## AGENTS.md / CLAUDE.md / Cursor rules

```text
Wax is the shared memory layer. Chat dies; Wax does not. Skip one-line Q&A. Use on any multi-step coding, debug, or research task.

Session lifecycle:
1. At session start call `session_open` (one-shot: fetches latest handoff + opens a session; pass `project` = repo name, stable `agent_id`/`run_id`, optional `recall_query`). Keep the returned `session_id`. Never invent one; never put it inside `metadata`.
2. After `/reload`, a restart, or returning to a task in the same repo, `session_open` resumes automatically; alternatively `handoff_latest` → `session_start`. Do not open duplicate sessions for the same work.
3. Close with `session_close` (`session_id`, `content`, optional `project`/`pending_tasks`) — atomic handoff then end.

Reading:
- `recall` (default `scope: project`) is the preferred read path. Empty lane is an explicit miss; pass `scope: global` only for cross-project reads. With `session_id`, recall merges that session's working memory with durable memory under project scope.
- `search` returns raw ranked hits. Prefer `mode: "text"` for exact names and recent facts, `mode: "hybrid"` when semantic retrieval helps.
- Long task needing all horizons at once: `compact_context`. Cross-session history with provenance: `corpus_search`.

Writing — immediately, not at the end of a task:
- Tactical (this task): `remember` with `scope: session` + top-level `session_id`, `memory_type: task_state`, `durability: working`. Write when you lock a plan, a path fails, you find a landmine / owner file / required gate, a milestone finishes, or before spawning a subagent / compacting / stopping. Read back with `recall` plus `session_id`.
- Strategic (survives the session): `remember` with `scope: durable` (no `session_id`), `memory_type` ∈ decision | lesson | constraint | user_preference | fact. Write on corrections, architecture/product decisions, pitfalls that would waste the next agent's time, stable repo facts.
- Example: `remember({ content: "What: auth uses JWT in src/auth.ts.\nWhy: stateless tokens for edge deploy.\nWhere: src/auth.ts\nLearned: refresh via middleware.", scope: "durable", memory_type: "decision" })`
- Content format: `What: / Why: / Where: / Learned:`. No secrets, transcripts, or huge logs. (`remember` takes no `title` argument.)
- Parent agents write to Wax before spawning children, and again from their evidence — children often have no Wax tools.

Structured memory: `entity_upsert` / `fact_assert` / `fact_retract` / `facts_query` / `entity_resolve` are for stable entities and graph-like facts, not transient debug notes.

Boundaries: don't manage `SESSION_STORE`, `--store-path`, or `flush` — the broker owns those. If Wax is unreachable or errors, proceed without memory; do not retry-loop.
```

## Hermes / OpenClaw SOUL.md

SOUL.md is identity. Append this section. Do not turn the whole soul into a tool manual.

```text
## Memory (Wax)

You have Wax. Chat is not memory.

On every multi-step task: prefer `session_open` (`project`, `agent_id`, `run_id`) or `handoff_latest` → `session_start` → keep `session_id`.

Write as you go:
- This task: `remember` with `scope: session`, `session_id`, `memory_type: task_state`, `durability: working` (plan, failed path, landmine, milestone, before you stop or spawn another agent).
- Long-term: `remember` with `scope: durable` (no `session_id`), type `decision` / `lesson` / `constraint` / `user_preference` / `fact` (corrections, decisions, standing prefs, stable repo facts).

Read: `recall` defaults to project scope (no foreign/unlabeled frames). Need cross-project → `scope: global`. `recall` with `session_id` merges this session with durable memory. Need a budgeted mix → `compact_context`.

Close with `session_close` (or `handoff` then `session_end`). Do not invent a `session_id` or put it in `metadata`. Do not store secrets.
```
