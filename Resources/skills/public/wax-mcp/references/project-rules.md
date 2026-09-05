# Wax MCP project rules

Paste **AGENTS.md** after installing the Wax MCP server. For OpenClaw,
append the **SOUL.md** stanza if missing. If `## Memory (Wax)` already
exists, replace that section — do not leave two manuals.

Native Hermes is not this MCP playbook. Set `memory.provider: wax-memory`
only, call `wax_remember` / `wax_recall` / `wax_stats`, and do not pass a
Wax `session_id`. Omit `scope` for current-project recall; pass
`scope=global` for person facts. Do not add `wax-memory` to
`plugins.enabled`.

The inner `text` fences are what you copy. Keep them in lockstep with
`WaxMCPAgentPlaybook` in `Sources/WaxCLI/WaxCLICommand.swift` and the README
Agent Quick Start details.

## AGENTS.md / CLAUDE.md / Cursor rules

```text
Wax is shared memory. Chat dies; Wax does not.

Learn. Write the moment it would change the next agent's behavior — including a one-line correction or preference:
- user_preference — how this person works, who they are, standing corrections
- lesson — we got burned; do not do that again
- fact — a true thing about this repo or product the next agent needs
- decision / constraint — a choice that should bind later work

Skip only empty chit-chat. Store one or two sentences. Do not store chats, test logs, plan drafts, or secrets.

Open: call `session_open` (`project` = repo, stable `agent_id` / `run_id`). Keep `session_id`. Do not invent one. Same `agent_id`+`run_id` resumes. Same `agent_id`+project rebinds if exactly one live session exists. If more than one is live, open a new session — do not guess.

Before the first answer:
1. `recall` with `session_id`, `mode: text`, query = this job
2. `recall` with `session_id`, `scope: global`, `mode: text`, query = facts about this person / standing corrections
Empty project recall is a miss, not "I have no memory."

Lasting writes: `remember` with top-level `session_id` and `memory_type` `lesson` | `user_preference` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`. Type keeps them durable and stamps the project so default recall can find them. Person-facts still pass `session_id`; read them later with `scope: global`. Never put `session_id` in `metadata`.

This job only (not the default write): `remember` with `session_id`, `memory_type: task_state`, `durability: working` — plan lock, failed path, landmine, before you spawn or stop. Parent writes before spawning; children often have no Wax tools.

Close when the job ends, not between turns: `session_close` with `session_id`, a short state `content`, and `pending_tasks` for unfinished work. If a call returns inactive / `resumable: false`, call `session_open` again. Follow the MCP server instructions when present.
```

## Hermes / OpenClaw SOUL.md

SOUL.md is identity. Append this section if missing. If `## Memory (Wax)`
already exists, replace that section. Do not turn the whole soul into a tool
manual.

```text
## Memory (Wax)

You have Wax. Chat is not memory. Learn this person and keep it.

Write the moment it would change how you treat them or the work — including a one-line correction:
- user_preference — how they work, who they are, standing corrections
- lesson — we got burned
- fact — something true that should stick
- decision / constraint — a choice that should bind later work

Store one or two sentences. Do not store chats, status, or secrets.

On every real job: call `session_open` (`project` = the repo you are in, `agent_id` = your name, `run_id` = this conversation). Keep `session_id`. Do not invent one. Do not open per message. Do not close between turns.

Before you act:
1. `recall` with `session_id`, `mode: text`, query = this repo/job
2. `recall` with `session_id`, `scope: global`, `mode: text`, query = facts about this person

Lasting writes: `remember` with top-level `session_id` and `memory_type` `user_preference` | `lesson` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`.

This job only: `remember` with `session_id`, `memory_type: task_state`, `durability: working`.

Close with `session_close` (`session_id`, short `content`, `pending_tasks`) when the job ends. If a call returns inactive / `resumable: false`, call `session_open` again. Follow the MCP server instructions when present.
```
