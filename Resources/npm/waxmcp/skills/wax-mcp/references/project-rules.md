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
1. Call `session_open` (`project` = repo name, stable `agent_id`/`run_id`, optional `recall_query`). Keep `session_id`. Do not invent one. Do not call `handoff_latest` then `session_start` as the default open. The same `agent_id`+`run_id` resumes the active session. The same `agent_id`+resolved project rebinds if exactly one live session; stamp a new `run_id`; `rebound: true`. Multiple actives mint a new session — do not guess.
2. Call `recall` with default `scope: project` (hard-filters to resolved project; unlabeled/foreign frames excluded). Empty lane returns an explicit miss — pass `scope: global` only for cross-project reads. `recall` with `session_id` merges that session with durable memory under project scope.

Workflow rules:
- Use `remember` to store decisions, discoveries, and short factual notes. `memory_type` selects the horizon; explicit `scope` overrides. Do not put `session_id` inside `metadata`.
- Use `recall` for assembled context and `search` for raw ranked hits.
- Prefer `mode: "hybrid"` when the embedder is ready; otherwise use `mode: "text"`.
- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores.
- Close with `session_close` (`session_id`, `content`, optional `project`/`pending_tasks`) — atomic handoff then end. Or `handoff` then `session_end`. Do not require end between turns of one host chat. Close harvests promotable session facts into durable memory automatically. Do not call `memory_promote` or operator `memory-maintain` in the agent loop.
- Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
- Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.
- `task_state` is session-local working state: it requires an active top-level `session_id` and rejects `scope: durable`, `durability: durable`, and `locked`. To repair legacy durable task-state frames, run `task_state_migrate` with a distinct `destination_path`; it copies the complete store before changing only task-state trees. Use `dry_run: true` first and choose `orphan_policy: quarantine` (default) or `drop`.

Canonical verbs: `session_open`, `remember`, `recall`, `session_close`, `stats`, `memory_get`, `compact_context`, `session_resume`.
Daily `tools/list` is those eight. Aliases stay callable. Set `WAX_MCP_TOOLS=full` for the rest. Follow the MCP server `instructions` when present; this paste is a fallback.

Write horizon: `memory_type` selects the horizon. `task_state` or `handoff` need top-level `session_id`. Durable types (`decision` | `lesson` | `fact` | `constraint` | `user_preference`) stay durable even if `session_id` is present. `note` is session if `session_id` is present, else durable. Explicit `scope` overrides.

Tactical (this task) — write immediately, not at the end:
- `remember` with `scope: session`, top-level `session_id`, `memory_type: task_state`, `durability: working`
- When: you lock a plan, a path fails (what + why), you find a landmine / owner file / required gate, a milestone finishes, or you are about to spawn a subagent / compact / stop
- Read with `recall` plus `session_id`

Strategic (survives this session):
- `remember` with `memory_type` one of `decision` | `lesson` | `constraint` | `user_preference` | `fact` (durable even if `session_id` is present). Optional explicit `scope: durable`.
- When: the user corrects you, you make an architecture or product decision, a pitfall will waste the next agent time, a standing preference appears, or a repo fact is stable

Both horizons on a long task: `compact_context`.
`recall` with `session_id` merges that session with durable long-term memory under project scope. `search` with `session_id` is session-store only.

Share across agents: the parent writes before spawning. Children often have no Wax tools. The parent writes again from their evidence.

Close: `session_close` (`session_id`, `content`, `project`, `pending_tasks`) or `handoff` then `session_end`.

Do not put `session_id` in `metadata`. Do not store secrets, transcripts, or huge logs. Do not manage `SESSION_STORE`, `--store-path`, or `flush`. Do not call `memory-maintain` from the agent loop. Prefer `mode: "text"` for exact names and recent facts. Structured `entity_*` / `fact_*` tools are for stable graph facts, not debug notes.
```

## Hermes / OpenClaw SOUL.md

SOUL.md is identity. Append this section. Do not turn the whole soul into a tool manual.

```text
## Memory (Wax)

You have Wax. Chat is not memory.

On every multi-step task: call `session_open` (`project`, `agent_id`, `run_id`, optional `recall_query`). Keep `session_id`. Follow the MCP server instructions when present.

Write as you go:
- This task: `remember` with `scope: session`, `session_id`, `memory_type: task_state`, `durability: working` (plan, failed path, landmine, milestone, before you stop or spawn another agent).
- `task_state` requires an active session and is always working; never request durable or locked task state. Repair legacy records with `task_state_migrate` into a distinct complete-store copy after a dry run.
- Long-term: `remember` with type `decision` / `lesson` / `constraint` / `user_preference` / `fact` (durable even if `session_id` is present; corrections, decisions, standing prefs, stable repo facts).

Read: `recall` defaults to project scope (no foreign/unlabeled frames). Need cross-project → `scope: global`. `recall` with `session_id` merges this session with durable memory. Need a budgeted mix → `compact_context`.

Close with `session_close` (or `handoff` then `session_end`). Harvest is automatic; do not call `memory_promote` or `memory-maintain` in the agent loop. Do not invent a `session_id` or put it in `metadata`. Do not store secrets.
```
