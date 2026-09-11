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

Open once per host chat: call `session_open` (`project` = repo, stable `agent_id` / `run_id`, `conversation_id` = this host chat id, `recall_query` = this job). The MCP connection remembers `session_id`; omit it after that. Do not invent one. Same `agent_id`+`run_id` resumes. Same `conversation_id` resumes this chat even after close. Same `agent_id`+project rebinds if exactly one live session exists. If more than one is live, open a new session — do not guess.

session_open with recall_query is enough. Do not recall again on follow-ups unless the job changed. Person prefs are in `person`. Empty project recall is a miss, not "I have no memory."

Lasting writes: `remember` with `memory_type` `lesson` | `user_preference` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`. A successful save has `status: ok` and `committed: true`. If `committed` is false or the call errors, the write did not land — do not spawn children (they have no Wax tools). Never put `session_id` in `metadata`.

This job only (not the default write): `remember` with `memory_type: task_state`, `durability: working` before you spawn.

Close is a checkpoint, not a new life: `session_close` with a short state `content` and `pending_tasks` when the host conversation is done. Compaction is not close. `leftover_reasons` are harvest skips — ignore them. `remaining_active` is other sessions. If omit-id fails after reconnect, call `session_open` with the same `conversation_id`. Follow the MCP server instructions when present.
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

On every real job: call `session_open` (`project` = the repo you are in, `agent_id` = your name, `run_id` = this conversation, `conversation_id` = this host chat id, `recall_query` = this job). The MCP connection remembers `session_id`; omit it after that. Do not invent one. Do not open per message. Same `conversation_id` resumes this chat even after close.

session_open with recall_query is enough. Person prefs are in `person`. Do not recall again on follow-ups unless the job changed.

Lasting writes: `remember` with `memory_type` `user_preference` | `lesson` | `fact` | `decision` | `constraint`. Do not pass `scope: durable`. If `committed` is false, the write did not land — do not spawn children.

This job only: `remember` with `memory_type: task_state`, `durability: working`.

Close with `session_close` (short `content`, `pending_tasks`) when the host conversation is done. Compaction is not close. `leftover_reasons` are harvest skips — ignore them. If omit-id fails after reconnect, call `session_open` with the same `conversation_id`. Follow the MCP server instructions when present.
```
